{ SPDX-License-Identifier: MIT
  Copyright (c) 2026 Ingo Jache }

unit abdecker.util;

{ abdecker - internal helpers (messages, UTF-8, byte search, base64, files).
  Not part of the public API: use the unit abdecker. }

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
{$IFDEF FPC}
  SysUtils, Classes,
{$ELSE}
  System.SysUtils, System.Classes,
{$ENDIF}
  abdecker;

type
  EAbParse = class(Exception);   // internal parse error, never leaves the public API

  TByteBuf = record
    Data: TBytes;
    Len: Integer;
    procedure Clear;
    procedure Add(c: Byte);
    procedure AddBytes(const b: TBytes);
    procedure AddText(const s: string);  // ASCII only
    function AsBytes: TBytes;
  end;

procedure AddMsg(var Msgs: TAbMessages; Sev: TAbSeverity; const Code, Text: string);
function IMin(a, b: Integer): Integer;
{ The only conversions between UTF-8 bytes and string: under Delphi string
  is UTF-16, under FPC it holds UTF-8 (then both are plain copies) }
function Utf8Str(const b: TBytes; Start, Count: Integer): string;
function Utf8Bytes(const s: string): TBytes;
function MatchAt(const b: TBytes; l, p: Integer; const s: AnsiString): Boolean;
function FindAt(const b: TBytes; l, From: Integer; const s: AnsiString): Integer;
function FindBack(const b: TBytes; l: Integer; const s: AnsiString): Integer;
function LineOf(const b: TBytes; p: Integer): Integer;
function IsHexDigit(c: Byte): Boolean;
function HexVal(c: Byte): Integer;
function DecodeBase64(const s: string): TBytes;
function EncodeBase64(const b: TBytes): string;
function ReadAllBytes(const FileName: string; out Data: TBytes; var Msgs: TAbMessages): Boolean;
{ Marks an XML that abdecker wrote or changed: a comment with version, author
  and links right after the XML declaration. An earlier mark in the prolog is
  replaced; line breaks follow the file, a one-line file stays one line. }
function XmlMark(const Xml: TBytes): TBytes;
{ The invoice model as text, one 'key = value' per line (keys: BT/BG numbers).
  Norm: numbers without trailing zeros. Values are trimmed (except BT-20),
  Info and MeansCodes are left out, Unmapped only with WithUnmapped. Two
  models are the same if their dumps are. }
procedure DumpModel(const Inv: TEInvoice; Norm, WithUnmapped: Boolean; l: TStrings);

implementation

{ ===========================================================================
  Small helpers
  =========================================================================== }

procedure AddMsg(var Msgs: TAbMessages; Sev: TAbSeverity; const Code, Text: string);
var
  n: Integer;
begin
  n := Length(Msgs);
  SetLength(Msgs, n + 1);
  Msgs[n].Severity := Sev;
  Msgs[n].Code := Code;
  Msgs[n].Text := Text;
  Msgs[n].Origin := aboFile;
end;

function IMin(a, b: Integer): Integer;
begin
  if a < b then result := a else result := b;
end;

{ Single conversion point from UTF-8 bytes to string. In FPC (Lazarus
  default) string is UTF-8 already, so this becomes a plain copy. }
function Utf8Str(const b: TBytes; Start, Count: Integer): string;
begin
  if Count <= 0 then exit('');
{$IFDEF FPC}
  SetLength(result, Count);
  Move(b[Start], result[1], Count);
{$ELSE}
  result := TEncoding.UTF8.GetString(b, Start, Count);
{$ENDIF}
end;

function Utf8Bytes(const s: string): TBytes;
begin
{$IFDEF FPC}
  SetLength(result, Length(s));
  if Length(s) > 0 then Move(s[1], result[0], Length(s));
{$ELSE}
  result := TEncoding.UTF8.GetBytes(s);
{$ENDIF}
end;

function MatchAt(const b: TBytes; l, p: Integer; const s: AnsiString): Boolean;
var
  i: Integer;
begin
  result := false;
  if (p < 0) or (p + Length(s) > l) then exit;

  for i := 1 to Length(s) do begin
    if b[p + i - 1] <> Ord(s[i]) then exit;
  end;

  result := true;
end;

function FindAt(const b: TBytes; l, From: Integer; const s: AnsiString): Integer;
var
  i: Integer;
  c: Byte;
begin
  c := Ord(s[1]);

  for i := From to l - Length(s) do begin
    if (b[i] = c) and MatchAt(b, l, i, s) then exit(i);
  end;

  result := -1;
end;

function FindBack(const b: TBytes; l: Integer; const s: AnsiString): Integer;
var
  i: Integer;
  c: Byte;
begin
  c := Ord(s[1]);

  for i := l - Length(s) downto 0 do begin
    if (b[i] = c) and MatchAt(b, l, i, s) then exit(i);
  end;

  result := -1;
end;

function LineOf(const b: TBytes; p: Integer): Integer;
var
  i: Integer;
begin
  result := 1;
  if p > Length(b) then p := Length(b);

  for i := 0 to p - 1 do begin
    if b[i] = 10 then Inc(result);
  end;
end;

function IsHexDigit(c: Byte): Boolean;
begin
  result := ((c >= Ord('0')) and (c <= Ord('9'))) or
    ((c >= Ord('a')) and (c <= Ord('f'))) or ((c >= Ord('A')) and (c <= Ord('F')));
end;

function HexVal(c: Byte): Integer;
begin
  if c <= Ord('9') then begin
    result := c - Ord('0');
  end else if c >= Ord('a') then begin
    result := c - Ord('a') + 10;
  end else begin
    result := c - Ord('A') + 10;
  end;
end;

procedure TByteBuf.Clear;
begin
  Len := 0;
end;

procedure TByteBuf.Add(c: Byte);
begin
  if Len >= Length(Data) then begin
    SetLength(Data, Len * 2 + 64);
  end;

  Data[Len] := c;
  Inc(Len);
end;

procedure TByteBuf.AddBytes(const b: TBytes);
var
  n: Integer;
begin
  n := Length(b);
  if n = 0 then exit;

  if Len + n > Length(Data) then begin
    SetLength(Data, (Len + n) * 2);
  end;

  Move(b[0], Data[Len], n);
  Inc(Len, n);
end;

procedure TByteBuf.AddText(const s: string);
var
  i: Integer;
begin
  if Len + Length(s) > Length(Data) then begin
    SetLength(Data, (Len + Length(s)) * 2 + 64);
  end;

  for i := 1 to Length(s) do begin
    Data[Len] := Byte(Ord(s[i]));
    Inc(Len);
  end;
end;

function TByteBuf.AsBytes: TBytes;
begin
  result := Copy(Data, 0, Len);
end;

{ Base64 with the standard alphabet and padding, no line breaks }
function EncodeBase64(const b: TBytes): string;
const
  a: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
var
  i, n, v, p: Integer;
begin
  n := Length(b);
  SetLength(result, ((n + 2) div 3) * 4);
  p := 1;
  i := 0;
  while i < n do begin
    v := b[i] shl 16;
    if i + 1 < n then v := v or (b[i + 1] shl 8);
    if i + 2 < n then v := v or b[i + 2];
    result[p] := a[((v shr 18) and 63) + 1];
    result[p + 1] := a[((v shr 12) and 63) + 1];

    if i + 1 < n then begin
      result[p + 2] := a[((v shr 6) and 63) + 1];
    end else begin
      result[p + 2] := '=';
    end;

    if i + 2 < n then begin
      result[p + 3] := a[(v and 63) + 1];
    end else begin
      result[p + 3] := '=';
    end;

    Inc(p, 4);
    Inc(i, 3);
  end;
end;

{ Lenient base64 decoder: skips whitespace and padding, accepts the URL alphabet. }
function DecodeBase64(const s: string): TBytes;
var
  buf: TByteBuf;
  i, bits, acc, v: Integer;
  c: Char;
begin
  buf.Clear;
  acc := 0;
  bits := 0;

  for i := 1 to Length(s) do begin
    c := s[i];

    case c of
      'A'..'Z': v := Ord(c) - Ord('A');
      'a'..'z': v := Ord(c) - Ord('a') + 26;
      '0'..'9': v := Ord(c) - Ord('0') + 52;
      '+', '-': v := 62;
      '/', '_': v := 63;
    else
      continue;
    end;

    acc := (acc shl 6) or v;
    Inc(bits, 6);

    if bits >= 8 then begin
      Dec(bits, 8);
      buf.Add(Byte(acc shr bits));
      acc := acc and ((1 shl bits) - 1);
    end;
  end;

  result := buf.AsBytes;
end;


function ReadAllBytes(const FileName: string; out Data: TBytes; var Msgs: TAbMessages): Boolean;
var
  fs: TFileStream;
begin
  result := false;
  Data := nil;

  try
    fs := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);

    try
      SetLength(Data, fs.Size);

      if Length(Data) > 0 then begin
        fs.ReadBuffer(Data[0], Length(Data));
      end;
    finally
      fs.Free;
    end;

    result := true;
  except
    on e: Exception do
      AddMsg(Msgs, abError, 'FILE', Format('The file "%s" cannot be read: %s', [FileName, e.Message]));
  end;
end;

{ ===========================================================================
  Mark in the XML
  =========================================================================== }

function XmlMark(const Xml: TBytes): TBytes;
var
  l, p, q, k, start, stop: Integer;
  hasDecl, lines: Boolean;
  nl, cmt: string;
  ins: TBytes;
begin
  l := Length(Xml);
  p := 0;
  if (l >= 3) and (Xml[0] = $EF) and (Xml[1] = $BB) and (Xml[2] = $BF) then p := 3;
  hasDecl := MatchAt(Xml, l, p, '<?xml');

  if hasDecl then begin
    q := FindAt(Xml, l, p, '?>');
    if q < 0 then exit(Xml);
    p := q + 2;
  end;

  k := FindAt(Xml, l, 0, #10);
  lines := k >= 0;

  if lines then begin
    nl := #10;
    if (k > 0) and (Xml[k - 1] = 13) then nl := #13#10;
    cmt := '<!-- abdecker ' + AbdeckerVersion + ' by ' + AbdeckerAuthor + nl + '     ' + AbdeckerRepo + nl +
      '     ' + AbdeckerHome + ' -->';
  end else begin
    nl := '';
    cmt := '<!-- abdecker ' + AbdeckerVersion + ' by ' + AbdeckerAuthor + ', ' + AbdeckerRepo + ', ' +
      AbdeckerHome + ' -->';
  end;

  // an earlier mark among the comments and processing instructions of the prolog
  start := -1;
  stop := -1;
  q := p;

  repeat
    while (q < l) and ((Xml[q] = $20) or (Xml[q] = $09) or (Xml[q] = $0A) or (Xml[q] = $0D)) do begin
      Inc(q);
    end;

    if MatchAt(Xml, l, q, '<!--') then begin
      k := FindAt(Xml, l, q + 4, '-->');
      if k < 0 then break;

      if MatchAt(Xml, l, q, '<!-- abdecker ') then begin
        start := q;
        stop := k + 3;
        break;
      end;

      q := k + 3;
    end else if MatchAt(Xml, l, q, '<?') then begin
      k := FindAt(Xml, l, q + 2, '?>');
      if k < 0 then break;
      q := k + 2;
    end else begin
      break;
    end;
  until false;

  if start < 0 then begin
    start := p;
    stop := p;

    if hasDecl then begin
      cmt := nl + cmt;
    end else begin
      cmt := cmt + nl;
    end;
  end;

  ins := Utf8Bytes(cmt);
  SetLength(result, l - (stop - start) + Length(ins));

  if start > 0 then begin
    Move(Xml[0], result[0], start);
  end;

  if Length(ins) > 0 then begin
    Move(ins[0], result[start], Length(ins));
  end;

  if l > stop then begin
    Move(Xml[stop], result[start + Length(ins)], l - stop);
  end;
end;

{ ===========================================================================
  Model dump: language neutral text, one 'key = value' per line
  =========================================================================== }


const
  // Name, TradingName, IDs, LegalID, VATID, TaxNumber, LegalInfo, ElectronicAddress,
  // Line1, Line2, Line3, City, PostCode, Subdivision, Country, contact name, phone, email
  SellerKeys: array[0..17] of string = ('BT-27', 'BT-28', 'BT-29', 'BT-30', 'BT-31', 'BT-32', 'BT-33',
    'BT-34', 'BT-35', 'BT-36', 'BT-162', 'BT-37', 'BT-38', 'BT-39', 'BT-40', 'BT-41', 'BT-42', 'BT-43');
  BuyerKeys: array[0..17] of string = ('BT-44', 'BT-45', 'BT-46', 'BT-47', 'BT-48', 'Buyer.TaxNumber',
    'Buyer.LegalInfo', 'BT-49', 'BT-50', 'BT-51', 'BT-163', 'BT-52', 'BT-53', 'BT-54', 'BT-55',
    'BT-56', 'BT-57', 'BT-58');
  PayeeKeys: array[0..17] of string = ('BT-59', 'Payee.TradingName', 'BT-60', 'BT-61', 'Payee.VATID',
    'Payee.TaxNumber', 'Payee.LegalInfo', 'Payee.EAddress', 'Payee.Line1', 'Payee.Line2', 'Payee.Line3',
    'Payee.City', 'Payee.PostCode', 'Payee.Subdivision', 'Payee.Country', 'Payee.Contact',
    'Payee.Phone', 'Payee.Email');
  TaxRepKeys: array[0..17] of string = ('BT-62', 'TaxRep.TradingName', 'TaxRep.IDs', 'TaxRep.LegalID',
    'BT-63', 'TaxRep.TaxNumber', 'TaxRep.LegalInfo', 'TaxRep.EAddress', 'BT-64', 'BT-65', 'BT-164',
    'BT-66', 'BT-67', 'BT-68', 'BT-69', 'TaxRep.Contact', 'TaxRep.Phone', 'TaxRep.Email');

procedure DumpModel(const Inv: TEInvoice; Norm, WithUnmapped: Boolean; l: TStrings);
var
  i, j: Integer;
  pre: string;
  ln: TEInvoiceLine;

  procedure P(const Key, Value: string);
  var
    v: string;
  begin
    v := Value;
    if Key <> 'BT-20' then v := Trim(v);  // BT-20: line breaks matter (XRechnung Skonto)

    if v <> '' then begin
      l.Add(pre + Key + ' = ' + StringReplace(StringReplace(v, #13, '\r', [rfReplaceAll]),
        #10, '\n', [rfReplaceAll]));
    end;
  end;

  procedure PD(const Key: string; const d: TAbDecimal);
  begin
    if not d.Present then exit;
    if not d.Valid then begin
      P(Key, 'INVALID(' + d.Text + ')');
    end else if Norm then begin
      P(Key, d.Normalized.ToString);
    end else begin
      P(Key, d.ToString);
    end;
  end;

  procedure PID(const Key: string; const ID: TEInvoiceID);
  begin
    P(Key, ID.Value);
    P(Key + '-1', ID.Scheme);
  end;

  procedure PAddr(const k: array of string; const a: TEInvoiceAddress);
  begin
    P(k[0], a.Line1);
    P(k[1], a.Line2);
    P(k[2], a.Line3);
    P(k[3], a.City);
    P(k[4], a.PostCode);
    P(k[5], a.Subdivision);
    P(k[6], a.Country);
  end;

  procedure PParty(const k: array of string; const x: TEInvoiceParty);
  var
    n: Integer;
  begin
    P(k[0], x.Name);
    P(k[1], x.TradingName);
    for n := 0 to High(x.IDs) do begin
      PID(k[2] + '[' + IntToStr(n + 1) + ']', x.IDs[n]);
    end;
    PID(k[3], x.LegalID);
    P(k[4], x.VATID);
    P(k[5], x.TaxNumber);
    P(k[6], x.LegalInfo);
    PID(k[7], x.ElectronicAddress);
    PAddr([k[8], k[9], k[10], k[11], k[12], k[13], k[14]], x.Address);
    P(k[15], x.Contact.Name);
    P(k[16], x.Contact.Phone);
    P(k[17], x.Contact.Email);
  end;

  procedure PAC(const Grp: string; const AC: TEInvoiceAllowanceCharge; const k: array of string);
  begin
    PD(Grp + k[0], AC.Amount);
    PD(Grp + k[1], AC.BaseAmount);
    PD(Grp + k[2], AC.Percent);
    P(Grp + k[3], AC.TaxCategory);
    PD(Grp + k[4], AC.TaxRate);
    P(Grp + k[5], AC.Reason);
    P(Grp + k[6], AC.ReasonCode);
  end;

  function Idx(const Grp: string; n: Integer): string;
  begin
    result := Grp + '[' + IntToStr(n + 1) + '] ';
  end;

begin
  pre := '';
  P('BT-1', Inv.Number);
  P('BT-2', Inv.IssueDate);
  P('BT-3', Inv.TypeCode);
  P('BT-5', Inv.Currency);
  P('BT-6', Inv.TaxCurrency);
  P('BT-7', Inv.TaxPointDate);
  P('BT-8', Inv.TaxPointDateCode);
  P('BT-9', Inv.DueDate);
  P('BT-10', Inv.BuyerReference);
  P('BT-11', Inv.ProjectRef);
  P('BT-12', Inv.ContractRef);
  P('BT-13', Inv.OrderRef);
  P('BT-14', Inv.SalesOrderRef);
  P('BT-15', Inv.ReceivingAdviceRef);
  P('BT-16', Inv.DespatchAdviceRef);
  P('BT-17', Inv.TenderRef);
  PID('BT-18', Inv.InvoicedObject);
  P('BT-19', Inv.AccountingRef);
  P('BT-20', Inv.PaymentTerms);
  for i := 0 to High(Inv.Notes) do begin
    P(Idx('BG-1', i) + 'BT-21', Inv.Notes[i].SubjectCode);
    P(Idx('BG-1', i) + 'BT-22', Inv.Notes[i].Text);
  end;
  P('BT-23', Inv.BusinessProcess);
  P('BT-24', Inv.Specification);
  for i := 0 to High(Inv.PrecedingInvoices) do begin
    P(Idx('BG-3', i) + 'BT-25', Inv.PrecedingInvoices[i].Number);
    P(Idx('BG-3', i) + 'BT-26', Inv.PrecedingInvoices[i].Date);
  end;
  PParty(SellerKeys, Inv.Seller);
  PParty(BuyerKeys, Inv.Buyer);
  PParty(PayeeKeys, Inv.Payee);
  PParty(TaxRepKeys, Inv.TaxRepresentative);
  P('BT-70', Inv.Delivery.PartyName);
  PID('BT-71', Inv.Delivery.LocationID);
  P('BT-72', Inv.Delivery.Date);
  PAddr(['BT-75', 'BT-76', 'BT-165', 'BT-77', 'BT-78', 'BT-79', 'BT-80'], Inv.Delivery.Address);
  P('BT-73', Inv.PeriodStart);
  P('BT-74', Inv.PeriodEnd);
  P('BT-81', Inv.Payment.MeansCode);
  P('BT-82', Inv.Payment.MeansText);
  P('BT-83', Inv.Payment.RemittanceInfo);
  for i := 0 to High(Inv.Payment.Accounts) do begin
    P(Idx('BG-17', i) + 'BT-84', Inv.Payment.Accounts[i].IBAN);
    P(Idx('BG-17', i) + 'BT-85', Inv.Payment.Accounts[i].Name);
    P(Idx('BG-17', i) + 'BT-86', Inv.Payment.Accounts[i].BIC);
  end;
  P('BT-87', Inv.Payment.CardNumber);
  P('BT-88', Inv.Payment.CardHolder);
  P('BT-89', Inv.Payment.MandateID);
  P('BT-90', Inv.Payment.CreditorID);
  P('BT-91', Inv.Payment.DebitedAccount);
  for i := 0 to High(Inv.AllowancesCharges) do begin
    if Inv.AllowancesCharges[i].IsCharge then begin
      PAC(Idx('BG-21', i), Inv.AllowancesCharges[i],
        ['BT-99', 'BT-100', 'BT-101', 'BT-102', 'BT-103', 'BT-104', 'BT-105']);
    end else begin
      PAC(Idx('BG-20', i), Inv.AllowancesCharges[i],
        ['BT-92', 'BT-93', 'BT-94', 'BT-95', 'BT-96', 'BT-97', 'BT-98']);
    end;
  end;
  PD('BT-106', Inv.Totals.LineTotal);
  PD('BT-107', Inv.Totals.AllowanceTotal);
  PD('BT-108', Inv.Totals.ChargeTotal);
  PD('BT-109', Inv.Totals.TaxExclusive);
  PD('BT-110', Inv.Totals.TaxTotal);
  PD('BT-111', Inv.Totals.TaxTotalTaxCurrency);
  PD('BT-112', Inv.Totals.TaxInclusive);
  PD('BT-113', Inv.Totals.Prepaid);
  PD('BT-114', Inv.Totals.Rounding);
  PD('BT-115', Inv.Totals.DuePayable);
  for i := 0 to High(Inv.Taxes) do begin
    pre := Idx('BG-23', i);
    PD('BT-116', Inv.Taxes[i].TaxableAmount);
    PD('BT-117', Inv.Taxes[i].TaxAmount);
    P('BT-118', Inv.Taxes[i].Category);
    PD('BT-119', Inv.Taxes[i].Rate);
    P('BT-120', Inv.Taxes[i].ExemptionReason);
    P('BT-121', Inv.Taxes[i].ExemptionReasonCode);
  end;
  for i := 0 to High(Inv.Documents) do begin
    pre := Idx('BG-24', i);
    P('BT-122', Inv.Documents[i].ID);
    P('BT-123', Inv.Documents[i].Description);
    P('BT-124', Inv.Documents[i].URI);
    if Length(Inv.Documents[i].Content) > 0 then begin
      P('BT-125', IntToStr(Length(Inv.Documents[i].Content)) + ' Bytes');
    end;
    P('BT-125-1', Inv.Documents[i].MimeType);
    P('BT-125-2', Inv.Documents[i].FileName);
  end;
  for i := 0 to High(Inv.Lines) do begin
    pre := Idx('BG-25', i);
    ln := Inv.Lines[i];
    P('BT-126', ln.ID);
    P('ParentLine', ln.ParentID);
    P('BT-127', ln.Note);
    PID('BT-128', ln.ObjectID);
    PD('BT-129', ln.Quantity);
    P('BT-130', ln.UnitCode);
    PD('BT-131', ln.NetAmount);
    P('BT-132', ln.OrderLineRef);
    P('BT-133', ln.AccountingRef);
    P('BT-134', ln.PeriodStart);
    P('BT-135', ln.PeriodEnd);
    for j := 0 to High(ln.AllowancesCharges) do begin
      if ln.AllowancesCharges[j].IsCharge then begin
        PAC(Idx('BG-28', j), ln.AllowancesCharges[j],
          ['BT-141', 'BT-142', 'BT-143', 'TaxCategory', 'TaxRate', 'BT-144', 'BT-145']);
      end else begin
        PAC(Idx('BG-27', j), ln.AllowancesCharges[j],
          ['BT-136', 'BT-137', 'BT-138', 'TaxCategory', 'TaxRate', 'BT-139', 'BT-140']);
      end;
    end;
    PD('BT-146', ln.NetPrice);
    PD('BT-147', ln.PriceDiscount);
    PD('BT-148', ln.GrossPrice);
    PD('BT-149', ln.BaseQuantity);
    P('BT-150', ln.BaseQuantityUnit);
    P('BT-151', ln.TaxCategory);
    PD('BT-152', ln.TaxRate);
    P('BT-153', ln.ItemName);
    P('BT-154', ln.ItemDescription);
    P('BT-155', ln.SellerItemID);
    P('BT-156', ln.BuyerItemID);
    PID('BT-157', ln.StandardItemID);
    for j := 0 to High(ln.Classifications) do begin
      PID('BT-158[' + IntToStr(j + 1) + ']', ln.Classifications[j]);
    end;
    P('BT-159', ln.OriginCountry);
    for j := 0 to High(ln.Attributes) do begin
      P(Idx('BG-32', j) + 'BT-160', ln.Attributes[j].Name);
      P(Idx('BG-32', j) + 'BT-161', ln.Attributes[j].Value);
    end;
  end;
  pre := '';
  if WithUnmapped then begin
    for i := 0 to High(Inv.Unmapped) do begin
      P('Unmapped', Inv.Unmapped[i]);
    end;
  end;
end;

end.
