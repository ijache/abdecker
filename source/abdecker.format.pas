{ SPDX-License-Identifier: MIT
  Copyright (c) 2026 Ingo Jache }

unit abdecker.format;

{ abdecker - the own invoice format (JSON, see templates/), internal. Not
  part of the public API: use TAbdecker.InvoiceFromJson and InvoiceToJson.

  Reading (JSON -> model, for creating): placeholders, mapping, defaults and
  calculation. Errors of the format are collected (all of them, not only the
  first), each with line, column and the path of the field, e.g.
  'line 12, column 40: lines[2].price: "9,50" is not a number'.

  Writing (model -> JSON, for further processing): a reduced, flat view of
  any invoice. Field names as in the format where the meaning is the same,
  plus what processing needs beyond it (line amounts, VAT breakdown,
  document level allowances and charges ...). Not meant as input for
  creating: no round trip. }

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  abdecker;

function ReadInvoiceJson(const Json: TBytes; const Options: TAbJsonOptions; var Inv: TEInvoice;
  var Msgs: TAbMessages): TAbResult;
{ placeholder values: strings and numbers at the top level of a JSON object }
function ReadVarsJson(const Json: TBytes; var Vars: TAbStrings; var Msgs: TAbMessages): TAbResult;
{ the invoice as JSON for further processing (result with file, result code,
  invoice and messages; the invoice is empty unless R = abOK) }
function InvoiceJson(const FileName: string; r: TAbResult; const Inv: TEInvoice;
  const Msgs: TAbMessages): string;

implementation

uses
  abdecker.util, abdecker.json, abdecker.attach;

const
  SpecEN16931 = 'urn:cen.eu:en16931:2017';
  SpecXRechnung = 'urn:cen.eu:en16931:2017#compliant#urn:xeinkauf.de:kosit:xrechnung_3.0';
  PeppolBilling = 'urn:fdc:peppol.eu:2017:poacc:billing:01:1.0';
  ReasonReverseCharge = 'Steuerschuldnerschaft des Leistungsempfängers';
  ReasonSmallBusiness = 'Kleinunternehmer gemäß § 19 UStG';

  RootFields: array[0..19] of string = ('profile', 'type', 'number', 'issueDate', 'currency',
    'buyerReference', 'orderReference', 'period', 'deliveryDate', 'precedingInvoice', 'note', 'dueDate',
    'paymentTerms', 'cashDiscount', 'seller', 'buyer', 'vatMode', 'lines', 'attachments', 'totals');
  SellerFields: array[0..14] of string = ('name', 'street', 'line2', 'postcode', 'city', 'country', 'vatId',
    'taxNumber', 'id', 'legalInfo', 'contact', 'electronicAddress', 'iban', 'bic', 'accountName');
  BuyerFields: array[0..7] of string = ('name', 'street', 'line2', 'postcode', 'city', 'country', 'vatId',
    'electronicAddress');
  ContactFields: array[0..2] of string = ('name', 'phone', 'email');
  AddressFields: array[0..1] of string = ('scheme', 'id');
  PeriodFields: array[0..1] of string = ('start', 'end');
  PrecedingFields: array[0..1] of string = ('number', 'issueDate');
  DiscountFields: array[0..1] of string = ('days', 'percent');
  LineFields: array[0..6] of string = ('name', 'description', 'itemNumber', 'quantity', 'unit', 'price', 'vat');
  AttachmentFields: array[0..3] of string = ('file', 'name', 'content', 'description');
  TotalsFields: array[0..3] of string = ('net', 'vat', 'gross', 'due');

type
  TVatMode = (vmStandard, vmReverseCharge, vmSmallBusiness);

  TFormatReader = record
    Doc: TJDoc;
    Msgs: TAbMessages;
    Failed: Boolean;
    Today: TDateTime;
    Vars: TAbStrings;
    BaseDir: string;
    procedure Err(n: Integer; const Code, Path, Text: string);
    procedure ErrName(n: Integer; const Code, Path, Text: string);
    function Sub(const Path, Name: string): string;
    procedure CheckFields(n: Integer; const Path: string; const Allowed: array of string);
    function Obj(p: Integer; const Path, Name: string; const Allowed: array of string): Integer;
    function Arr(p: Integer; const Path, Name: string): Integer;
    function Lookup(n: Integer; const Path, Name: string; out Value: string): Boolean;
    function Subst(n: Integer; const Path, s: string): string;
    function Str(p: Integer; const Path, Name: string): string;
    function Num(p: Integer; const Path, Name: string): TAbDecimal;
    function DateVal(p: Integer; const Path, Name: string): string;
    function Need(p: Integer; const Path, Name: string): Boolean;
  end;

{ ---- small helpers ---- }

function DateText(d: TDateTime): string;
var
  y, m, dd: Word;
begin
  DecodeDate(d, y, m, dd);
  result := Format('%.4d-%.2d-%.2d', [y, m, dd]);
end;

{ YYYY-MM-DD with a real calendar date }
function ParseDate(const s: string; out d: TDateTime): Boolean;
var
  i, y, m, dd: Integer;
begin
  result := false;
  d := 0;
  if (Length(s) <> 10) or (s[5] <> '-') or (s[8] <> '-') then exit;

  for i := 1 to 10 do begin
    if (i <> 5) and (i <> 8) and ((s[i] < '0') or (s[i] > '9')) then exit;
  end;

  y := StrToInt(Copy(s, 1, 4));
  m := StrToInt(Copy(s, 6, 2));
  dd := StrToInt(Copy(s, 9, 2));
  if (y < 1) or (m < 1) or (m > 12) or (dd < 1) or (dd > MonthDays[IsLeapYear(y), m]) then exit;
  d := EncodeDate(y, m, dd);
  result := true;
end;

{ an amount with exactly two decimals, rounded half away from zero }
function Amount2(const d: TAbDecimal): TAbDecimal;
begin
  result := d.Rounded(2);

  while result.Valid and (result.Scale < 2) do begin
    result.Value := result.Value * 10;
    Inc(result.Scale);
  end;
end;

function UnitCode(const s: string): string;
begin
  if s = 'hour' then result := 'HUR'
  else if s = 'day' then result := 'DAY'
  else if s = 'month' then result := 'MON'
  else if s = 'piece' then result := 'H87'
  else if s = 'lump' then result := 'LS'
  else if s = 'km' then result := 'KMT'
  else result := s;
end;

function KindName(k: TJKind): string;
begin
  case k of
    jkNull: result := 'null';
    jkFalse, jkTrue: result := 'a boolean';
    jkNumber: result := 'a number';
    jkString: result := 'a string';
    jkArray: result := 'an array';
  else
    result := 'an object';
  end;
end;

{ ---- reader ---- }

procedure TFormatReader.Err(n: Integer; const Code, Path, Text: string);
var
  where: string;
begin
  where := '';

  if (n >= 0) and (n < Doc.Count) then begin
    where := Format('line %d, column %d: ', [Doc.Nodes[n].Line, Doc.Nodes[n].Col]);
  end;

  if Path <> '' then where := where + Path + ': ';
  AddMsg(Msgs, abError, Code, where + Text);
  Failed := true;
end;

{ an error about the member name of N (unknown, duplicate): at the name }
procedure TFormatReader.ErrName(n: Integer; const Code, Path, Text: string);
begin
  AddMsg(Msgs, abError, Code, Format('line %d, column %d: %s: %s', [Doc.Nodes[n].NameLine, Doc.Nodes[n].NameCol,
    Path, Text]));
  Failed := true;
end;

function TFormatReader.Sub(const Path, Name: string): string;
begin
  if Path = '' then begin
    result := Name;
  end else begin
    result := Path + '.' + Name;
  end;
end;

{ unknown and duplicate member names of object N }
procedure TFormatReader.CheckFields(n: Integer; const Path: string; const Allowed: array of string);
var
  c, d, i: Integer;
  known: Boolean;
begin
  c := Doc.Nodes[n].FirstChild;

  while c >= 0 do begin
    known := false;

    for i := 0 to High(Allowed) do begin
      if Doc.Nodes[c].Name = Allowed[i] then begin
        known := true;
        break;
      end;
    end;

    if not known then ErrName(c, 'JSON-FIELD', Sub(Path, Doc.Nodes[c].Name), 'unknown field');
    d := Doc.Nodes[n].FirstChild;

    while d <> c do begin
      if Doc.Nodes[d].Name = Doc.Nodes[c].Name then begin
        ErrName(c, 'JSON-DUPLICATE', Sub(Path, Doc.Nodes[c].Name), 'field given twice');
        break;
      end;

      d := Doc.Nodes[d].Next;
    end;

    c := Doc.Nodes[c].Next;
  end;
end;

{ member Name of P as an object (-1 if absent or of the wrong type) }
function TFormatReader.Obj(p: Integer; const Path, Name: string; const Allowed: array of string): Integer;
begin
  result := Doc.Member(p, Name);
  if result < 0 then exit;

  if Doc.Nodes[result].Kind <> jkObject then begin
    Err(result, 'JSON-TYPE', Sub(Path, Name), 'an object expected, not ' + KindName(Doc.Nodes[result].Kind));
    exit(-1);
  end;

  CheckFields(result, Sub(Path, Name), Allowed);
end;

function TFormatReader.Arr(p: Integer; const Path, Name: string): Integer;
begin
  result := Doc.Member(p, Name);
  if result < 0 then exit;

  if Doc.Nodes[result].Kind <> jkArray then begin
    Err(result, 'JSON-TYPE', Sub(Path, Name), 'an array expected, not ' + KindName(Doc.Nodes[result].Kind));
    result := -1;
  end;
end;

{ value of a placeholder: the caller's variables, then the built-ins }
function TFormatReader.Lookup(n: Integer; const Path, Name: string; out Value: string): Boolean;
var
  i, k: Integer;
  y, m, d: Word;
  first: TDateTime;
  digits: string;
begin
  result := true;

  for i := 0 to High(Vars) do begin
    k := Pos('=', Vars[i]);

    if (k > 1) and (Trim(Copy(Vars[i], 1, k - 1)) = Name) then begin
      Value := Copy(Vars[i], k + 1, MaxInt);
      exit;
    end;
  end;

  if Name = 'today' then begin
    Value := DateText(Today);
    exit;
  end;

  if Copy(Name, 1, 6) = 'today+' then begin
    digits := Copy(Name, 7, MaxInt);
    k := StrToIntDef(digits, -1);

    if (digits <> '') and (Length(digits) <= 5) and (k >= 0) and (IntToStr(k) = digits) then begin
      Value := DateText(Today + k);
      exit;
    end;
  end;

  DecodeDate(Today, y, m, d);
  first := EncodeDate(y, m, 1);  // first day of this month

  if Name = 'prevMonthEnd' then begin
    Value := DateText(first - 1);
    exit;
  end;

  if Name = 'prevMonthStart' then begin
    DecodeDate(first - 1, y, m, d);
    Value := DateText(EncodeDate(y, m, 1));
    exit;
  end;

  Err(n, 'JSON-PLACEHOLDER', Path, Format('unknown placeholder {{%s}}', [Name]));
  Value := '';
  result := false;
end;

// placeholders {{name}} replaced in a string value; single braces stay as they are
function TFormatReader.Subst(n: Integer; const Path, s: string): string;
var
  p, q: Integer;
  name, value: string;
begin
  result := '';
  p := 1;

  repeat
    q := Pos('{{', Copy(s, p, MaxInt));

    if q = 0 then begin
      result := result + Copy(s, p, MaxInt);
      break;
    end;

    result := result + Copy(s, p, q - 1);
    p := p + q + 1;
    q := Pos('}}', Copy(s, p, MaxInt));

    if q = 0 then begin
      Err(n, 'JSON-PLACEHOLDER', Path, '"{{" without "}}"');
      break;
    end;

    name := Trim(Copy(s, p, q - 1));
    if Lookup(n, Path, name, value) then result := result + value;
    p := p + q + 1;
  until false;
end;

{ member Name of P as a string, placeholders replaced; '' if absent }
function TFormatReader.Str(p: Integer; const Path, Name: string): string;
var
  n: Integer;
begin
  result := '';
  n := Doc.Member(p, Name);
  if n < 0 then exit;

  if Doc.Nodes[n].Kind <> jkString then begin
    Err(n, 'JSON-TYPE', Sub(Path, Name), 'a string expected, not ' + KindName(Doc.Nodes[n].Kind));
    exit;
  end;

  result := Subst(n, Sub(Path, Name), Doc.Nodes[n].Value);
end;

{ member Name of P as a number: a JSON number or a string (placeholders),
  read as text; no exponent. Absent: Present = False }
function TFormatReader.Num(p: Integer; const Path, Name: string): TAbDecimal;
var
  n, k: Integer;
  s: string;
begin
  result := Default(TAbDecimal);
  n := Doc.Member(p, Name);
  if n < 0 then exit;

  case Doc.Nodes[n].Kind of
    jkNumber: s := Doc.Nodes[n].Value;
    jkString:
      begin
        k := Length(Msgs);
        s := Subst(n, Sub(Path, Name), Doc.Nodes[n].Value);
        if Length(Msgs) > k then exit;  // the placeholder is reported already
      end;
  else
    Err(n, 'JSON-TYPE', Sub(Path, Name), 'a number expected, not ' + KindName(Doc.Nodes[n].Kind));
    exit;
  end;

  result := TAbDecimal.Parse(s);

  if not result.Present or not result.Valid then begin
    Err(n, 'JSON-VALUE', Sub(Path, Name), Format('"%s" is not a number (digits with "." as decimal point)', [s]));
    result := Default(TAbDecimal);
  end;
end;

function TFormatReader.DateVal(p: Integer; const Path, Name: string): string;
var
  d: TDateTime;
begin
  result := Str(p, Path, Name);

  if (result <> '') and not ParseDate(result, d) then begin
    Err(Doc.Member(p, Name), 'JSON-VALUE', Sub(Path, Name), Format('"%s" is not a date (YYYY-MM-DD)', [result]));
  end;
end;

{ a required member; reports it if absent }
function TFormatReader.Need(p: Integer; const Path, Name: string): Boolean;
begin
  result := Doc.Member(p, Name) >= 0;
  if not result then Err(p, 'JSON-MISSING', Sub(Path, Name), 'required');
end;

{ ---- mapping ---- }

procedure ReadAddress(var r: TFormatReader; p: Integer; const Path: string; var a: TEInvoiceAddress);
begin
  a.Line1 := r.Str(p, Path, 'street');
  a.Line2 := r.Str(p, Path, 'line2');
  a.PostCode := r.Str(p, Path, 'postcode');
  a.City := r.Str(p, Path, 'city');
  a.Country := r.Str(p, Path, 'country');
  if a.Country = '' then a.Country := 'DE';
end;

// a string = e-mail (EM), else an object with "scheme" and "id"
procedure ReadElectronicAddress(var r: TFormatReader; p: Integer; const Path: string; var ID: TEInvoiceID);
var
  n: Integer;
begin
  n := r.Doc.Member(p, 'electronicAddress');
  if n < 0 then exit;

  if r.Doc.Nodes[n].Kind = jkString then begin
    ID.Value := r.Str(p, Path, 'electronicAddress');
    ID.Scheme := 'EM';
    exit;
  end;

  n := r.Obj(p, Path, 'electronicAddress', AddressFields);
  if n < 0 then exit;
  r.Need(n, Path + '.electronicAddress', 'scheme');
  r.Need(n, Path + '.electronicAddress', 'id');
  ID.Scheme := r.Str(n, Path + '.electronicAddress', 'scheme');
  ID.Value := r.Str(n, Path + '.electronicAddress', 'id');
end;

procedure ReadSeller(var r: TFormatReader; Root: Integer; var Inv: TEInvoice);
var
  p, c: Integer;
  id: TEInvoiceID;
  acc: TEInvoiceAccount;
begin
  if not r.Need(Root, '', 'seller') then exit;
  p := r.Obj(Root, '', 'seller', SellerFields);
  if p < 0 then exit;
  Inv.Seller.Name := r.Str(p, 'seller', 'name');
  ReadAddress(r, p, 'seller', Inv.Seller.Address);
  Inv.Seller.VATID := r.Str(p, 'seller', 'vatId');
  Inv.Seller.TaxNumber := r.Str(p, 'seller', 'taxNumber');
  Inv.Seller.LegalInfo := r.Str(p, 'seller', 'legalInfo');
  id.Value := r.Str(p, 'seller', 'id');
  id.Scheme := '';

  // BR-CO-26 needs BT-29, BT-30 or BT-31; without both the tax number serves as BT-29
  if (id.Value = '') and (Inv.Seller.VATID = '') then id.Value := Inv.Seller.TaxNumber;

  if id.Value <> '' then begin
    SetLength(Inv.Seller.IDs, 1);
    Inv.Seller.IDs[0] := id;
  end;

  c := r.Obj(p, 'seller', 'contact', ContactFields);

  if c >= 0 then begin
    Inv.Seller.Contact.Name := r.Str(c, 'seller.contact', 'name');
    Inv.Seller.Contact.Phone := r.Str(c, 'seller.contact', 'phone');
    Inv.Seller.Contact.Email := r.Str(c, 'seller.contact', 'email');
  end;

  ReadElectronicAddress(r, p, 'seller', Inv.Seller.ElectronicAddress);
  acc.IBAN := r.Str(p, 'seller', 'iban');
  acc.BIC := r.Str(p, 'seller', 'bic');
  acc.Name := r.Str(p, 'seller', 'accountName');

  if acc.IBAN <> '' then begin
    SetLength(Inv.Payment.Accounts, 1);
    Inv.Payment.Accounts[0] := acc;
  end else if (acc.BIC <> '') or (acc.Name <> '') then begin
    r.Err(p, 'JSON-MISSING', 'seller.iban', 'required with seller.bic or seller.accountName');
  end;
end;

procedure ReadBuyer(var r: TFormatReader; Root: Integer; var Inv: TEInvoice);
var
  p: Integer;
begin
  if not r.Need(Root, '', 'buyer') then exit;
  p := r.Obj(Root, '', 'buyer', BuyerFields);
  if p < 0 then exit;
  Inv.Buyer.Name := r.Str(p, 'buyer', 'name');
  ReadAddress(r, p, 'buyer', Inv.Buyer.Address);
  Inv.Buyer.VATID := r.Str(p, 'buyer', 'vatId');
  ReadElectronicAddress(r, p, 'buyer', Inv.Buyer.ElectronicAddress);
end;

procedure ReadLines(var r: TFormatReader; Root: Integer; Mode: TVatMode; var Inv: TEInvoice);
var
  a, p, i: Integer;
  path: string;
  l: TEInvoiceLine;
begin
  if not r.Need(Root, '', 'lines') then exit;
  a := r.Arr(Root, '', 'lines');
  if a < 0 then exit;
  if r.Doc.Nodes[a].FirstChild < 0 then r.Err(a, 'JSON-MISSING', 'lines', 'at least one line required');
  p := r.Doc.Nodes[a].FirstChild;
  i := 0;

  while p >= 0 do begin
    path := Format('lines[%d]', [i + 1]);

    if r.Doc.Nodes[p].Kind <> jkObject then begin
      r.Err(p, 'JSON-TYPE', path, 'an object expected, not ' + KindName(r.Doc.Nodes[p].Kind));
    end else begin
      r.CheckFields(p, path, LineFields);
      l := Default(TEInvoiceLine);
      l.ID := IntToStr(i + 1);
      l.ItemName := r.Str(p, path, 'name');
      l.ItemDescription := r.Str(p, path, 'description');
      l.SellerItemID := r.Str(p, path, 'itemNumber');
      l.UnitCode := UnitCode(r.Str(p, path, 'unit'));
      r.Need(p, path, 'quantity');
      r.Need(p, path, 'price');
      l.Quantity := r.Num(p, path, 'quantity');
      l.NetPrice := r.Num(p, path, 'price');

      case Mode of
        vmStandard:
          begin
            r.Need(p, path, 'vat');
            l.TaxCategory := 'S';
            l.TaxRate := r.Num(p, path, 'vat');
          end;
        vmReverseCharge:
          begin
            l.TaxCategory := 'AE';
            l.TaxRate := TAbDecimal.FromInt(0);
          end;
      else
        l.TaxCategory := 'E';
        l.TaxRate := TAbDecimal.FromInt(0);
      end;

      if (Mode <> vmStandard) and (r.Doc.Member(p, 'vat') >= 0) then begin
        r.ErrName(r.Doc.Member(p, 'vat'), 'JSON-FIELD', path + '.vat', 'not allowed with this vatMode (abdecker sets it)');
      end;

      if l.Quantity.Present and l.NetPrice.Present then begin
        l.NetAmount := Amount2(l.Quantity.Mul(l.NetPrice));
      end;

      SetLength(Inv.Lines, Length(Inv.Lines) + 1);
      Inv.Lines[High(Inv.Lines)] := l;
    end;

    p := r.Doc.Nodes[p].Next;
    Inc(i);
  end;
end;

procedure ReadAttachments(var r: TFormatReader; Root: Integer; var Inv: TEInvoice);
var
  a, p, i, j: Integer;
  path, fileName, fullName, content: string;
  d: TEInvoiceDocument;
  m: TAbMessages;
  data: TBytes;
  got: Boolean;
begin
  a := r.Arr(Root, '', 'attachments');
  if a < 0 then exit;
  p := r.Doc.Nodes[a].FirstChild;
  i := 0;

  while p >= 0 do begin
    path := Format('attachments[%d]', [i + 1]);

    if r.Doc.Nodes[p].Kind <> jkObject then begin
      r.Err(p, 'JSON-TYPE', path, 'an object expected, not ' + KindName(r.Doc.Nodes[p].Kind));
      p := r.Doc.Nodes[p].Next;
      Inc(i);
      continue;
    end;

    r.CheckFields(p, path, AttachmentFields);
    d := Default(TEInvoiceDocument);
    d.Description := r.Str(p, path, 'description');
    fileName := r.Str(p, path, 'file');
    content := r.Str(p, path, 'content');
    data := nil;
    got := false;

    if (fileName <> '') = (r.Doc.Member(p, 'content') >= 0) then begin
      r.Err(p, 'JSON-ATTACHMENT', path, 'either "file" or "name" and "content" (base64)');
    end else if fileName <> '' then begin
      if r.Doc.Member(p, 'name') >= 0 then r.Err(p, 'JSON-ATTACHMENT', path, '"name" goes with "content", not "file"');

      if r.BaseDir = '' then begin
        r.Err(p, 'JSON-ATTACHMENT', path + '.file', 'files cannot be read here; use "name" and "content" (base64)');
      end else begin
        fullName := fileName;
        if ExtractFileDrive(fullName) = '' then fullName := IncludeTrailingPathDelimiter(r.BaseDir) + fullName;
        m := nil;

        got := ReadAllBytes(fullName, data, m);

        if not got then begin
          r.Err(r.Doc.Member(p, 'file'), 'JSON-ATTACHMENT', path + '.file', Format('"%s" cannot be read', [fileName]));
        end;
      end;

      d.FileName := Copy(fileName, LastDelimiter('/\:', fileName) + 1, MaxInt);
    end else begin
      r.Need(p, path, 'name');
      d.FileName := r.Str(p, path, 'name');
      data := DecodeBase64(content);
      got := true;
    end;

    if d.FileName <> '' then begin
      d.ID := d.FileName;
      d.MimeType := MimeForFileName(d.FileName);
      d.Content := data;

      if (d.MimeType = '') or not AllowedMime(d.MimeType) then begin
        r.Err(p, 'JSON-ATTACHMENT', path, Format('"%s": this file type is not allowed in e-invoices (allowed: %s)',
          [d.FileName, AllowedMimeList]));
      end else if got and (Length(data) = 0) then begin
        r.Err(p, 'JSON-ATTACHMENT', path, Format('"%s" is empty', [d.FileName]));
      end;

      for j := 0 to High(Inv.Documents) do begin
        if SameText(Inv.Documents[j].FileName, d.FileName) then begin
          r.Err(p, 'JSON-ATTACHMENT', path, Format('"%s" is given twice', [d.FileName]));
        end;
      end;

      SetLength(Inv.Documents, Length(Inv.Documents) + 1);
      Inv.Documents[High(Inv.Documents)] := d;
    end;

    p := r.Doc.Nodes[p].Next;
    Inc(i);
  end;
end;

{ VAT breakdown per category and rate (in the order of the lines) and the totals }
procedure Calculate(Mode: TVatMode; var Inv: TEInvoice);
var
  i, j: Integer;
  found: Boolean;
  t: TEInvoiceTax;
  lines, tax: TAbDecimal;
begin
  lines := TAbDecimal.FromInt(0, 2);
  tax := TAbDecimal.FromInt(0, 2);

  for i := 0 to High(Inv.Lines) do begin
    found := false;

    for j := 0 to High(Inv.Taxes) do begin
      if (Inv.Taxes[j].Category = Inv.Lines[i].TaxCategory) and Inv.Taxes[j].Rate.Equals(Inv.Lines[i].TaxRate) then begin
        Inv.Taxes[j].TaxableAmount := Inv.Taxes[j].TaxableAmount.Add(Inv.Lines[i].NetAmount);
        found := true;
        break;
      end;
    end;

    if not found then begin
      t := Default(TEInvoiceTax);
      t.Category := Inv.Lines[i].TaxCategory;
      t.Rate := Inv.Lines[i].TaxRate;
      t.TaxableAmount := Amount2(Inv.Lines[i].NetAmount);

      case Mode of
        vmReverseCharge:
          begin
            t.ExemptionReason := ReasonReverseCharge;
            t.ExemptionReasonCode := 'VATEX-EU-AE';
          end;
        vmSmallBusiness: t.ExemptionReason := ReasonSmallBusiness;
      end;

      SetLength(Inv.Taxes, Length(Inv.Taxes) + 1);
      Inv.Taxes[High(Inv.Taxes)] := t;
    end;

    lines := lines.Add(Inv.Lines[i].NetAmount);
  end;

  for j := 0 to High(Inv.Taxes) do begin
    Inv.Taxes[j].TaxableAmount := Amount2(Inv.Taxes[j].TaxableAmount);
    Inv.Taxes[j].TaxAmount := Amount2(Inv.Taxes[j].TaxableAmount.Mul(Inv.Taxes[j].Rate).Divide(TAbDecimal.FromInt(100), 2));
    tax := tax.Add(Inv.Taxes[j].TaxAmount);
  end;

  Inv.Totals.LineTotal := Amount2(lines);
  Inv.Totals.TaxExclusive := Inv.Totals.LineTotal;
  Inv.Totals.TaxTotal := Amount2(tax);
  Inv.Totals.TaxInclusive := Amount2(Inv.Totals.TaxExclusive.Add(Inv.Totals.TaxTotal));
  Inv.Totals.DuePayable := Inv.Totals.TaxInclusive;
end;

{ given totals must match the calculated ones }
procedure CompareTotals(var r: TFormatReader; Root: Integer; const Inv: TEInvoice);
var
  p: Integer;

  procedure One(const Name: string; const Calc: TAbDecimal);
  var
    given: TAbDecimal;
  begin
    given := r.Num(p, 'totals', Name);

    if given.Present and Calc.Valid and not given.Equals(Calc) then begin
      r.Err(r.Doc.Member(p, Name), 'JSON-TOTALS', 'totals.' + Name, Format('%s given, %s calculated',
        [given.ToString, Calc.ToString]));
    end;
  end;

begin
  p := r.Obj(Root, '', 'totals', TotalsFields);
  if p < 0 then exit;
  One('net', Inv.Totals.TaxExclusive);
  One('vat', Inv.Totals.TaxTotal);
  One('gross', Inv.Totals.TaxInclusive);
  One('due', Inv.Totals.DuePayable);
end;

function ReadInvoiceJson(const Json: TBytes; const Options: TAbJsonOptions; var Inv: TEInvoice;
  var Msgs: TAbMessages): TAbResult;
var
  r: TFormatReader;
  root, p: Integer;
  s, terms: string;
  mode: TVatMode;
  note: TEInvoiceNote;
  ref: TEInvoiceReference;
  days, percent: TAbDecimal;
  i: Integer;
begin
  r := Default(TFormatReader);
  r.Vars := Options.Vars;
  r.BaseDir := Options.BaseDir;

  if Options.Today = '' then begin
    r.Today := Date;
  end else if not ParseDate(Options.Today, r.Today) then begin
    r.Err(-1, 'JSON-OPTION', '', Format('"today" is not a date (YYYY-MM-DD): "%s"', [Options.Today]));
  end;

  for i := 0 to High(Options.Vars) do begin
    if Pos('=', Options.Vars[i]) < 2 then begin
      r.Err(-1, 'JSON-OPTION', '', Format('variable without "name=": "%s"', [Options.Vars[i]]));
    end;
  end;

  if r.Failed then begin
    Msgs := Concat(Msgs, r.Msgs);
    exit(abInvalidData);
  end;

  if not JsonParse(Json, r.Doc) then begin
    AddMsg(Msgs, abError, 'JSON-SYNTAX', 'Broken JSON: ' + r.Doc.Error);
    exit(abInvalidData);
  end;

  root := 0;

  if r.Doc.Nodes[root].Kind <> jkObject then begin
    r.Err(root, 'JSON-TYPE', '', 'the invoice must be a JSON object');
    Msgs := Concat(Msgs, r.Msgs);
    exit(abInvalidData);
  end;

  r.CheckFields(root, '', RootFields);

  // document
  s := r.Str(root, '', 'profile');

  if (s = '') or (s = 'en16931') then begin
    Inv.Specification := SpecEN16931;
    Inv.Info.Profile := eiprofEN16931;
  end else if s = 'xrechnung' then begin
    Inv.Specification := SpecXRechnung;
    Inv.Info.Profile := eiprofXRechnung;
    Inv.Info.XRechnungVersion := '3.0';
  end else begin
    r.Err(r.Doc.Member(root, 'profile'), 'JSON-VALUE', 'profile', Format('"%s": expected "en16931" or "xrechnung"', [s]));
  end;

  Inv.Info.Container := eicontXML;
  Inv.Info.Syntax := eisynCII;
  Inv.Info.GuidelineID := Inv.Specification;
  Inv.BusinessProcess := PeppolBilling;

  s := r.Str(root, '', 'type');

  if (s = '') or (s = 'invoice') then begin
    Inv.TypeCode := '380';
  end else if s = 'correction' then begin
    Inv.TypeCode := '381';
  end else begin
    r.Err(r.Doc.Member(root, 'type'), 'JSON-VALUE', 'type', Format('"%s": expected "invoice" or "correction"', [s]));
  end;

  Inv.Number := r.Str(root, '', 'number');
  Inv.IssueDate := r.DateVal(root, '', 'issueDate');
  if r.Doc.Member(root, 'issueDate') < 0 then Inv.IssueDate := DateText(r.Today);
  Inv.Currency := r.Str(root, '', 'currency');
  if Inv.Currency = '' then Inv.Currency := 'EUR';
  Inv.BuyerReference := r.Str(root, '', 'buyerReference');
  Inv.OrderRef := r.Str(root, '', 'orderReference');

  p := r.Obj(root, '', 'period', PeriodFields);

  if p >= 0 then begin
    Inv.PeriodStart := r.DateVal(p, 'period', 'start');
    Inv.PeriodEnd := r.DateVal(p, 'period', 'end');
  end;

  Inv.Delivery.Date := r.DateVal(root, '', 'deliveryDate');
  p := r.Obj(root, '', 'precedingInvoice', PrecedingFields);

  if p >= 0 then begin
    r.Need(p, 'precedingInvoice', 'number');
    ref.Number := r.Str(p, 'precedingInvoice', 'number');
    ref.Date := r.DateVal(p, 'precedingInvoice', 'issueDate');
    SetLength(Inv.PrecedingInvoices, 1);
    Inv.PrecedingInvoices[0] := ref;
  end;

  note.SubjectCode := '';
  note.Text := r.Str(root, '', 'note');

  if note.Text <> '' then begin
    SetLength(Inv.Notes, 1);
    Inv.Notes[0] := note;
  end;

  // VAT
  s := r.Str(root, '', 'vatMode');
  mode := vmStandard;

  if s = 'reverse-charge' then begin
    mode := vmReverseCharge;
  end else if s = 'small-business' then begin
    mode := vmSmallBusiness;
  end else if (s <> '') and (s <> 'standard') then begin
    r.Err(r.Doc.Member(root, 'vatMode'), 'JSON-VALUE', 'vatMode',
      Format('"%s": expected "standard", "reverse-charge" or "small-business"', [s]));
  end;

  ReadSeller(r, root, Inv);
  ReadBuyer(r, root, Inv);
  ReadLines(r, root, mode, Inv);
  ReadAttachments(r, root, Inv);

  // payment: credit transfer to seller.iban; a correction without IBAN is settled (97)
  Inv.DueDate := r.DateVal(root, '', 'dueDate');

  if Length(Inv.Payment.Accounts) > 0 then begin
    Inv.Payment.MeansCode := '58';
  end else if Inv.TypeCode = '381' then begin
    Inv.Payment.MeansCode := '97';
  end else if r.Doc.Member(root, 'seller') >= 0 then begin
    r.Err(r.Doc.Member(root, 'seller'), 'JSON-MISSING', 'seller.iban', 'required (payment by credit transfer)');
  end;

  terms := r.Str(root, '', 'paymentTerms');
  p := r.Obj(root, '', 'cashDiscount', DiscountFields);

  if p >= 0 then begin
    r.Need(p, 'cashDiscount', 'days');
    r.Need(p, 'cashDiscount', 'percent');
    days := r.Num(p, 'cashDiscount', 'days');
    percent := r.Num(p, 'cashDiscount', 'percent');

    if days.Present and ((days.Normalized.Scale <> 0) or (days.Sign <= 0)) then begin
      r.Err(r.Doc.Member(p, 'days'), 'JSON-VALUE', 'cashDiscount.days', 'a whole number of days expected');
    end;

    if days.Present and percent.Present then begin
      // XRechnung syntax (BR-DE-18): one line per discount, ending with a line break
      if terms <> '' then terms := terms + #10;
      terms := terms + Format('#SKONTO#TAGE=%s#PROZENT=%s#', [days.Normalized.ToString, Amount2(percent).ToString]) + #10;
    end;
  end;

  Inv.PaymentTerms := terms;

  Calculate(mode, Inv);
  CompareTotals(r, root, Inv);

  Msgs := Concat(Msgs, r.Msgs);

  if r.Failed then begin
    Inv := Default(TEInvoice);
    exit(abInvalidData);
  end;

  result := abOK;
end;

function ReadVarsJson(const Json: TBytes; var Vars: TAbStrings; var Msgs: TAbMessages): TAbResult;
var
  doc: TJDoc;
  n: Integer;
begin
  Vars := nil;

  if not JsonParse(Json, doc) then begin
    AddMsg(Msgs, abError, 'JSON-SYNTAX', 'Broken JSON: ' + doc.Error);
    exit(abInvalidData);
  end;

  if doc.Nodes[0].Kind <> jkObject then begin
    AddMsg(Msgs, abError, 'JSON-TYPE', 'The variables must be a JSON object');
    exit(abInvalidData);
  end;

  n := doc.Nodes[0].FirstChild;

  while n >= 0 do begin
    if doc.Nodes[n].Kind in [jkString, jkNumber] then begin
      SetLength(Vars, Length(Vars) + 1);
      Vars[High(Vars)] := doc.Nodes[n].Name + '=' + doc.Nodes[n].Value;
    end;

    n := doc.Nodes[n].Next;
  end;

  result := abOK;
end;

{ ---- writer ----
  Empty fields are left out. Values are built inside out: a member is
  '"key": value' or '' (left out), an object or array is '' if all its
  members are; elements of an array always stay (at least an empty object), so the
  positions match the invoice. }

const
  LF = #10;

type
  TFormatWriter = record
    Msgs: TAbMessages;
    function Num(const Path: string; const d: TAbDecimal): string;
  end;

{ a number exactly as in the invoice; an unusable one is left out with a warning }
function TFormatWriter.Num(const Path: string; const d: TAbDecimal): string;
begin
  result := '';
  if not d.Present then exit;
  if d.Valid and (d.Value <> Low(Int64)) then exit(d.ToString);
  AddMsg(Msgs, abWarning, 'JSON-NUMBER', Format('%s: "%s" is not a number, left out', [Path, d.Text]));
end;

function Str(const s: string): string;
begin
  if s = '' then begin
    result := '';
  end else begin
    result := JsonStr(s);
  end;
end;

function Pair(const Key, Value: string): string;
begin
  if Value = '' then begin
    result := '';
  end else begin
    result := JsonStr(Key) + ': ' + Value;
  end;
end;

{ the non-empty items, one per line, indented by Indent + 2 }
function Block(const Open, Close: string; const Items: array of string; Indent: Integer): string;
var
  i: Integer;
begin
  result := '';

  for i := 0 to High(Items) do begin
    if Items[i] = '' then continue;
    if result <> '' then result := result + ',';
    result := result + LF + StringOfChar(' ', Indent + 2) + Items[i];
  end;

  if result <> '' then result := Open + result + LF + StringOfChar(' ', Indent) + Close;
end;

function Obj(const Items: array of string; Indent: Integer): string;
begin
  result := Block('{', '}', Items, Indent);
end;

procedure AddElement(var List: TAbStrings; const Value: string);
begin
  SetLength(List, Length(List) + 1);

  if Value = '' then begin
    List[High(List)] := '{}';
  end else begin
    List[High(List)] := Value;
  end;
end;

function Arr(const List: TAbStrings; Indent: Integer): string;
begin
  result := Block('[', ']', List, Indent);
end;

function IDJson(const ID: TEInvoiceID; Indent: Integer): string;
begin
  result := Obj([Pair('scheme', Str(ID.Scheme)), Pair('id', Str(ID.Value))], Indent);
end;

function FirstID(const IDs: TEInvoiceIDs): string;
begin
  if Length(IDs) = 0 then begin
    result := '';
  end else begin
    result := IDs[0].Value;
  end;
end;

function SellerJson(const Inv: TEInvoice; Indent: Integer): string;
var
  p: TEInvoiceParty;
  acc: TEInvoiceAccount;
begin
  p := Inv.Seller;
  acc := Default(TEInvoiceAccount);
  if Length(Inv.Payment.Accounts) > 0 then acc := Inv.Payment.Accounts[0];

  result := Obj([
    Pair('name', Str(p.Name)),
    Pair('street', Str(p.Address.Line1)),
    Pair('line2', Str(p.Address.Line2)),
    Pair('line3', Str(p.Address.Line3)),
    Pair('postcode', Str(p.Address.PostCode)),
    Pair('city', Str(p.Address.City)),
    Pair('country', Str(p.Address.Country)),
    Pair('vatId', Str(p.VATID)),
    Pair('taxNumber', Str(p.TaxNumber)),
    Pair('id', Str(FirstID(p.IDs))),
    Pair('legalInfo', Str(p.LegalInfo)),
    Pair('contact', Obj([
      Pair('name', Str(p.Contact.Name)),
      Pair('phone', Str(p.Contact.Phone)),
      Pair('email', Str(p.Contact.Email))], Indent + 2)),
    Pair('electronicAddress', IDJson(p.ElectronicAddress, Indent + 2)),
    Pair('iban', Str(acc.IBAN)),
    Pair('bic', Str(acc.BIC)),
    Pair('accountName', Str(acc.Name))], Indent);
end;

function BuyerJson(const p: TEInvoiceParty; Indent: Integer): string;
begin
  result := Obj([
    Pair('name', Str(p.Name)),
    Pair('street', Str(p.Address.Line1)),
    Pair('line2', Str(p.Address.Line2)),
    Pair('line3', Str(p.Address.Line3)),
    Pair('postcode', Str(p.Address.PostCode)),
    Pair('city', Str(p.Address.City)),
    Pair('country', Str(p.Address.Country)),
    Pair('vatId', Str(p.VATID)),
    Pair('id', Str(FirstID(p.IDs))),
    Pair('electronicAddress', IDJson(p.ElectronicAddress, Indent + 2))], Indent);
end;

function LinesJson(var w: TFormatWriter; const Inv: TEInvoice; Indent: Integer): string;
var
  i: Integer;
  l: TEInvoiceLine;
  path: string;
  list: TAbStrings;
begin
  list := nil;

  for i := 0 to High(Inv.Lines) do begin
    l := Inv.Lines[i];
    path := Format('lines[%d].', [i + 1]);
    AddElement(list, Obj([
      Pair('name', Str(l.ItemName)),
      Pair('description', Str(l.ItemDescription)),
      Pair('itemNumber', Str(l.SellerItemID)),
      Pair('quantity', w.Num(path + 'quantity', l.Quantity)),
      Pair('unit', Str(l.UnitCode)),
      Pair('price', w.Num(path + 'price', l.NetPrice)),
      Pair('baseQuantity', w.Num(path + 'baseQuantity', l.BaseQuantity)),
      Pair('net', w.Num(path + 'net', l.NetAmount)),
      Pair('vat', w.Num(path + 'vat', l.TaxRate)),
      Pair('vatCategory', Str(l.TaxCategory))], Indent + 2));
  end;

  result := Arr(list, Indent);
end;

function AllowancesChargesJson(var w: TFormatWriter; const Inv: TEInvoice; Indent: Integer): string;
const
  Bool: array[Boolean] of string = ('false', 'true');
var
  i: Integer;
  a: TEInvoiceAllowanceCharge;
  path: string;
  list: TAbStrings;
begin
  list := nil;

  for i := 0 to High(Inv.AllowancesCharges) do begin
    a := Inv.AllowancesCharges[i];
    path := Format('allowancesCharges[%d].', [i + 1]);
    AddElement(list, Obj([
      Pair('charge', Bool[a.IsCharge]),
      Pair('amount', w.Num(path + 'amount', a.Amount)),
      Pair('reason', Str(a.Reason)),
      Pair('vat', w.Num(path + 'vat', a.TaxRate)),
      Pair('vatCategory', Str(a.TaxCategory))], Indent + 2));
  end;

  result := Arr(list, Indent);
end;

function VatJson(var w: TFormatWriter; const Inv: TEInvoice; Indent: Integer): string;
var
  i: Integer;
  t: TEInvoiceTax;
  path: string;
  list: TAbStrings;
begin
  list := nil;

  for i := 0 to High(Inv.Taxes) do begin
    t := Inv.Taxes[i];
    path := Format('vat[%d].', [i + 1]);
    AddElement(list, Obj([
      Pair('category', Str(t.Category)),
      Pair('rate', w.Num(path + 'rate', t.Rate)),
      Pair('net', w.Num(path + 'net', t.TaxableAmount)),
      Pair('vat', w.Num(path + 'vat', t.TaxAmount)),
      Pair('exemptionReason', Str(t.ExemptionReason))], Indent + 2));
  end;

  result := Arr(list, Indent);
end;

function DocumentsJson(const Inv: TEInvoice; Indent: Integer): string;
var
  i: Integer;
  d: TEInvoiceDocument;
  size: string;
  list: TAbStrings;
begin
  list := nil;

  for i := 0 to High(Inv.Documents) do begin
    d := Inv.Documents[i];
    size := '';
    if Length(d.Content) > 0 then size := IntToStr(Length(d.Content));
    AddElement(list, Obj([
      Pair('id', Str(d.ID)),
      Pair('name', Str(d.FileName)),
      Pair('description', Str(d.Description)),
      Pair('mimeType', Str(d.MimeType)),
      Pair('uri', Str(d.URI)),
      Pair('size', size)], Indent + 2));
  end;

  result := Arr(list, Indent);
end;

function InvoiceJson(const FileName: string; r: TAbResult; const Inv: TEInvoice;
  const Msgs: TAbMessages): string;
var
  w: TFormatWriter;
  body, note, preceding: string;
  i: Integer;
begin
  w := Default(TFormatWriter);
  body := '';

  if r = abOK then begin
    note := '';

    for i := 0 to High(Inv.Notes) do begin
      if Inv.Notes[i].Text = '' then continue;
      if note <> '' then note := note + LF;
      note := note + Inv.Notes[i].Text;
    end;

    preceding := '';

    if Length(Inv.PrecedingInvoices) > 0 then begin
      preceding := Obj([
        Pair('number', Str(Inv.PrecedingInvoices[0].Number)),
        Pair('issueDate', Str(Inv.PrecedingInvoices[0].Date))], 4);
    end;

    body := Obj([
      Pair('typeCode', Str(Inv.TypeCode)),
      Pair('number', Str(Inv.Number)),
      Pair('issueDate', Str(Inv.IssueDate)),
      Pair('dueDate', Str(Inv.DueDate)),
      Pair('currency', Str(Inv.Currency)),
      Pair('buyerReference', Str(Inv.BuyerReference)),
      Pair('orderReference', Str(Inv.OrderRef)),
      Pair('period', Obj([Pair('start', Str(Inv.PeriodStart)), Pair('end', Str(Inv.PeriodEnd))], 4)),
      Pair('deliveryDate', Str(Inv.Delivery.Date)),
      Pair('precedingInvoice', preceding),
      Pair('note', Str(note)),
      Pair('paymentTerms', Str(Inv.PaymentTerms)),
      Pair('seller', SellerJson(Inv, 4)),
      Pair('buyer', BuyerJson(Inv.Buyer, 4)),
      Pair('paymentMeans', Str(Inv.Payment.MeansCode)),
      Pair('lines', LinesJson(w, Inv, 4)),
      Pair('allowancesCharges', AllowancesChargesJson(w, Inv, 4)),
      Pair('vat', VatJson(w, Inv, 4)),
      Pair('totals', Obj([
        Pair('net', w.Num('totals.net', Inv.Totals.TaxExclusive)),
        Pair('vat', w.Num('totals.vat', Inv.Totals.TaxTotal)),
        Pair('gross', w.Num('totals.gross', Inv.Totals.TaxInclusive)),
        Pair('prepaid', w.Num('totals.prepaid', Inv.Totals.Prepaid)),
        Pair('rounding', w.Num('totals.rounding', Inv.Totals.Rounding)),
        Pair('due', w.Num('totals.due', Inv.Totals.DuePayable))], 4)),
      Pair('attachments', DocumentsJson(Inv, 4))], 2);
  end;

  if body = '' then body := '{}';

  result := '{' + LF +
    '  "file": ' + JsonStr(FileName) + ',' + LF +
    '  "result": ' + JsonStr(ResultCodes[r]) + ',' + LF +
    '  "syntax": ' + JsonStr(SyntaxCodes[Inv.Info.Syntax]) + ',' + LF +
    '  "profile": ' + JsonStr(ProfileCodes[Inv.Info.Profile]) + ',' + LF +
    '  "xrechnungVersion": ' + JsonStr(Inv.Info.XRechnungVersion) + ',' + LF +
    '  "invoice": ' + body + ',' + LF +
    MessageList(Concat(Msgs, w.Msgs)) + LF + '}';
end;

end.
