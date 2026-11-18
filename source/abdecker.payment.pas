{ SPDX-License-Identifier: MIT
  Copyright (c) 2026 Ingo Jache }

unit abdecker.payment;

{ abdecker - what is to be paid, and the GiroCode for it (internal). Not
  part of the public API: use TAbdecker.GiroCode and the HTML page.

  The GiroCode is the EPC QR code (EPC069-12, version 002, UTF-8) for a SEPA
  credit transfer: only EUR, a valid IBAN, an amount from 0.01 to
  999999999.99. Recipient: account name (BT-85), else payee (BT-59), else
  seller (BT-27). Remittance: BT-83, else the invoice number; a valid
  creditor reference (ISO 11649, "RF..") goes into the structured field.
  Skonto from the XRechnung lines in BT-20 (#SKONTO#TAGE=n#PROZENT=n.nn#):
  the percentage of BASISBETRAG, else of the amount due (BT-115); the days
  are counted from the invoice date. }

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

type
  TPayKind = (
    pkNone,          // nothing said about payment
    pkTransfer,      // credit transfer (or an account is given)
    pkDirectDebit,   // the seller collects the amount (49, 59)
    pkNothingToPay,  // amount due 0
    pkCredit,        // credit note or negative amount: the buyer gets money
    pkOther);        // cash, cheque, card, clearing ...

  TPayNoCode = (
    pncNone,         // there is a code
    pncCurrency,     // not EUR
    pncNoAccount,    // no account given
    pncNoIBAN,       // the account is no IBAN (e.g. a national account number)
    pncIBAN,         // the account looks like an IBAN, but is not valid
    pncAmount,       // amount missing or unusable
    pncName,         // no recipient name
    pncTooLong);     // the text would exceed 331 bytes

  TPayDiscount = record
    Days: Integer;
    Percent: TAbDecimal;
    Amount: TAbDecimal;   // to pay with the discount
    Deadline: string;     // ISO date: invoice date + days, '' without invoice date
    Code: string;         // GiroCode for Amount, '' if none
  end;
  TPayDiscounts = array of TPayDiscount;

  TPayInfo = record
    Kind: TPayKind;
    Amount: TAbDecimal;   // amount due (BT-115); pkCredit: its absolute value
    Currency: string;
    Name: string;         // recipient of the transfer
    IBAN: string;         // without spaces
    BIC: string;
    IsIBAN: Boolean;      // looks like an IBAN (two letters, two digits), else an account number
    IBANValid: Boolean;
    Remittance: string;   // BT-83, else the invoice number
    DueDate: string;      // BT-9
    Code: string;         // GiroCode for Amount, '' if none
    NoCode: TPayNoCode;   // pkTransfer: why there is no code
    Discounts: TPayDiscounts;  // pkTransfer: Skonto
    OtherAccounts: Integer;    // further accounts with an IBAN (shown, not used)
  end;

function PaymentInfo(const Inv: TEInvoice): TPayInfo;

implementation

uses
  abdecker.util, abdecker.check;

const
  MaxCodeBytes = 331;

function IsCreditNoteType(const Code: string): Boolean;
begin
  result := (Code = '81') or (Code = '83') or (Code = '261') or (Code = '262') or (Code = '296') or
    (Code = '308') or (Code = '381') or (Code = '396') or (Code = '420') or (Code = '458') or (Code = '532');
end;

function NoSpaces(const s: string): string;
var
  i: Integer;
begin
  result := '';

  for i := 1 to Length(s) do begin
    if s[i] > ' ' then result := result + s[i];
  end;
end;

{ one line of the code: line breaks and tabs become spaces, cut after Max
  characters (code points, not bytes or UTF-16 units) }
function Field(const s: string; Max: Integer): string;
var
  b: TBytes;
  i, n: Integer;
begin
  result := s;

  for i := 1 to Length(result) do begin
    if result[i] < ' ' then result[i] := ' ';
  end;

  result := Trim(result);
  b := Utf8Bytes(result);
  n := 0;

  for i := 0 to High(b) do begin
    if (b[i] and $C0) <> $80 then begin
      Inc(n);
      if n > Max then exit(Utf8Str(b, 0, i));
    end;
  end;
end;

{ creditor reference ISO 11649: RF, two check digits, up to 21 letters/digits, mod 97 = 1 }
function IsCreditorRef(const s: string): Boolean;
var
  t: string;
  i, m, v: Integer;
begin
  result := false;
  t := UpperCase(NoSpaces(s));
  if (Length(t) < 5) or (Length(t) > 25) or (Copy(t, 1, 2) <> 'RF') then exit;
  t := Copy(t, 5, MaxInt) + Copy(t, 1, 4);
  m := 0;

  for i := 1 to Length(t) do begin
    case t[i] of
      '0'..'9': m := (m * 10 + Ord(t[i]) - Ord('0')) mod 97;
      'A'..'Z': begin
        v := Ord(t[i]) - Ord('A') + 10;
        m := (m * 100 + v) mod 97;
      end;
    else
      exit;
    end;
  end;

  result := m = 1;
end;

{ two letters, two digits: meant as an IBAN (then a wrong one is an error) }
function LooksLikeIBAN(const s: string): Boolean;
begin
  result := (Length(s) >= 5) and (s[1] >= 'A') and (s[1] <= 'Z') and (s[2] >= 'A') and (s[2] <= 'Z') and
    (s[3] >= '0') and (s[3] <= '9') and (s[4] >= '0') and (s[4] <= '9');
end;

function UsableAmount(const d: TAbDecimal): Boolean;
begin
  result := d.Present and d.Valid and (d.Sign > 0) and (d.Normalized.Scale <= 2) and
    (d.Compare(TAbDecimal.Parse('999999999.99')) <= 0);
end;

{ always with two decimals: EUR12.30 }
function Cents(const d: TAbDecimal): string;
var
  r: TAbDecimal;
begin
  r := d.Rounded(2);

  while r.Scale < 2 do begin
    r.Value := r.Value * 10;
    Inc(r.Scale);
  end;

  result := r.ToString;
end;

{ the EPC text, '' if it would be too long }
function GiroCodeText(const p: TPayInfo; const Amount: TAbDecimal): string;
var
  lines: array[0..10] of string;
  i, last: Integer;
  ref: string;
begin
  lines[0] := 'BCD';
  lines[1] := '002';
  lines[2] := '1';            // UTF-8
  lines[3] := 'SCT';
  lines[4] := p.BIC;
  lines[5] := Field(p.Name, 70);
  lines[6] := p.IBAN;
  lines[7] := 'EUR' + Cents(Amount);
  lines[8] := '';             // purpose
  lines[9] := '';             // structured remittance (creditor reference)
  lines[10] := '';            // unstructured remittance
  ref := Field(p.Remittance, 140);

  if IsCreditorRef(ref) then begin
    lines[9] := UpperCase(NoSpaces(ref));
  end else begin
    lines[10] := ref;
  end;

  last := 10;
  while lines[last] = '' do Dec(last);
  result := '';

  for i := 0 to last do begin
    if i > 0 then result := result + #10;
    result := result + lines[i];
  end;

  if Length(Utf8Bytes(result)) > MaxCodeBytes then result := '';
end;

function AddDays(const IsoDate: string; Days: Integer): string;
var
  y, m, d: Integer;
  dt: TDateTime;
  yy, mm, dd: Word;
begin
  result := '';
  if (Length(IsoDate) <> 10) or (IsoDate[5] <> '-') or (IsoDate[8] <> '-') then exit;
  if not TryStrToInt(Copy(IsoDate, 1, 4), y) or not TryStrToInt(Copy(IsoDate, 6, 2), m) or
    not TryStrToInt(Copy(IsoDate, 9, 2), d) then exit;
  if not TryEncodeDate(y, m, d, dt) then exit;
  DecodeDate(dt + Days, yy, mm, dd);
  result := Format('%.4d-%.2d-%.2d', [yy, mm, dd]);
end;

{ the Skonto lines of BT-20 }
procedure AddDiscounts(const Inv: TEInvoice; var p: TPayInfo);
var
  terms, line, part, base: string;
  start, i, k, days: Integer;
  pct, b, m: TAbDecimal;
  dsc: TPayDiscount;
begin
  terms := Inv.PaymentTerms + #10;
  start := 1;

  for i := 1 to Length(terms) do begin
    if terms[i] <> #10 then continue;
    line := Trim(Copy(terms, start, i - start));
    start := i + 1;
    if not SkontoLineOK(line) then continue;
    // #SKONTO#TAGE=n#PROZENT=n.nn(#BASISBETRAG=n.nn)?#
    days := 0;
    pct := Default(TAbDecimal);
    base := '';
    line := Copy(line, 2, Length(line) - 2);

    while line <> '' do begin
      k := Pos('#', line);
      if k = 0 then k := Length(line) + 1;
      part := Copy(line, 1, k - 1);
      line := Copy(line, k + 1, MaxInt);
      if Copy(part, 1, 5) = 'TAGE=' then days := StrToIntDef(Copy(part, 6, MaxInt), 0)
      else if Copy(part, 1, 8) = 'PROZENT=' then pct := TAbDecimal.Parse(Copy(part, 9, MaxInt))
      else if Copy(part, 1, 12) = 'BASISBETRAG=' then base := Copy(part, 13, MaxInt);
    end;

    if base <> '' then begin
      b := TAbDecimal.Parse(base);
    end else begin
      b := p.Amount;
    end;

    if not (b.Valid and pct.Valid) then continue;
    dsc := Default(TPayDiscount);
    dsc.Days := days;
    dsc.Percent := pct;
    // percentage of the base, exact (scale + 2), then rounded to cents
    m := b.Mul(pct);
    if not m.Valid or (m.Scale > 16) then continue;
    Inc(m.Scale, 2);
    dsc.Amount := p.Amount.Sub(m.Rounded(2));
    dsc.Deadline := AddDays(Inv.IssueDate, days);
    if (p.Code <> '') and UsableAmount(dsc.Amount) then dsc.Code := GiroCodeText(p, dsc.Amount);
    SetLength(p.Discounts, Length(p.Discounts) + 1);
    p.Discounts[High(p.Discounts)] := dsc;
  end;
end;

function PaymentInfo(const Inv: TEInvoice): TPayInfo;
var
  means: string;
  due: TAbDecimal;
  i: Integer;
  found: Boolean;
begin
  result := Default(TPayInfo);
  means := Inv.Payment.MeansCode;
  due := Inv.Totals.DuePayable;
  result.Amount := due;
  result.Currency := Inv.Currency;
  result.DueDate := Inv.DueDate;
  found := false;

  for i := 0 to High(Inv.Payment.Accounts) do begin
    if NoSpaces(Inv.Payment.Accounts[i].IBAN) = '' then continue;

    if found then begin
      Inc(result.OtherAccounts);
    end else begin
      found := true;
      result.IBAN := UpperCase(NoSpaces(Inv.Payment.Accounts[i].IBAN));
      result.BIC := UpperCase(NoSpaces(Inv.Payment.Accounts[i].BIC));
      result.Name := Inv.Payment.Accounts[i].Name;
    end;
  end;

  if due.Present and due.Valid and ((due.Sign < 0) or ((due.Sign > 0) and IsCreditNoteType(Inv.TypeCode))) then begin
    result.Kind := pkCredit;
    if due.Sign < 0 then result.Amount := TAbDecimal.FromInt(0).Sub(due);
    exit;
  end;

  if due.Present and due.Valid and due.IsZero then begin
    result.Kind := pkNothingToPay;
    exit;
  end;

  if (means = '49') or (means = '59') then begin
    result.Kind := pkDirectDebit;
    exit;
  end;

  if (means = '10') or (means = '20') or (means = '48') or (means = '54') or (means = '55') or (means = '97') then begin
    result.Kind := pkOther;
    exit;
  end;

  if found or (means = '30') or (means = '42') or (means = '58') then begin
    result.Kind := pkTransfer;
  end else begin
    if means <> '' then result.Kind := pkOther;
    exit;
  end;

  if result.Name = '' then result.Name := Inv.Payee.Name;
  if result.Name = '' then result.Name := Inv.Seller.Name;
  result.Remittance := Trim(Inv.Payment.RemittanceInfo);
  if result.Remittance = '' then result.Remittance := Inv.Number;
  result.IsIBAN := LooksLikeIBAN(result.IBAN);
  result.IBANValid := found and CheckIBAN(result.IBAN);

  if UpperCase(Inv.Currency) <> 'EUR' then begin
    result.NoCode := pncCurrency;
  end else if not found then begin
    result.NoCode := pncNoAccount;
  end else if not result.IsIBAN then begin
    result.NoCode := pncNoIBAN;
  end else if not result.IBANValid then begin
    result.NoCode := pncIBAN;
  end else if not UsableAmount(due) then begin
    result.NoCode := pncAmount;
  end else if Field(result.Name, 70) = '' then begin
    result.NoCode := pncName;
  end else begin
    result.Code := GiroCodeText(result, due);
    if result.Code = '' then result.NoCode := pncTooLong;
  end;

  AddDiscounts(Inv, result);
end;

end.
