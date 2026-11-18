{ SPDX-License-Identifier: MIT
  Copyright (c) 2026 Ingo Jache }

unit abdecker.check;

{ abdecker - plausibility check (internal). Not part of the public API: use
  the unit abdecker.

  Rule IDs are those of the official rule sets (EN 16931 validation artefacts,
  XRechnung 3.0 schematron incl. the Peppol rules it uses), so results can be
  compared with the KoSIT validator. Texts and severities come from
  data/rules.txt (generated into abdecker.rules.inc by tools/gen-data.py).

  Principle: report only what is implemented completely. If a rule cannot be
  decided reliably from the model (invalid numbers, several payment means,
  sub-lines ...), it stays silent and the report says what was not checked.

  Every rule records whether it was applied (Report.Rules): Req applies the
  rule it tests, Fail applies it, too. A rule counts as applied where the
  invoice contains what the rule is about and the rule could be decided; so
  a rule that holds is "passed", one about absent content "not applied".
  Where a check keeps a plain "if violated then Fail", Apply marks that
  place. }

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

procedure CheckInvoice(const Inv: TEInvoice; var r: TAbCheckReport);
{ IBAN check as in the XRechnung schematron (structure + mod 97), spaces ignored }
function CheckIBAN(const s: string): Boolean;
{ one Skonto line of XRechnung: #SKONTO#TAGE=n#PROZENT=n.nn(#BASISBETRAG=-n.nn)?# }
function SkontoLineOK(const s: string): Boolean;

implementation

uses
  abdecker.util;

type
  TRuleInfo = record
    ID: string;
    Severity: TAbSeverity;
    Text: string;
  end;

{$I abdecker.rules.inc}

const
  XR_CIUS_ID = 'urn:cen.eu:en16931:2017#compliant#urn:xeinkauf.de:kosit:xrechnung_3.0';
  XR_EXTENSION_ID = XR_CIUS_ID + '#conformant#urn:xeinkauf.de:kosit:extension:xrechnung_3.0';
  XR_CVD_ID = XR_CIUS_ID + '#compliant#urn:xeinkauf.de:kosit:xrechnung:cvd_0.9';

{ ===========================================================================
  Helpers
  =========================================================================== }

function InList(const l: array of string; const s: string): Boolean;
var
  lo, hi, mid, c: Integer;
begin
  lo := 0;
  hi := High(l);
  while lo <= hi do begin
    mid := (lo + hi) div 2;
    c := CompareStr(l[mid], s);
    if c = 0 then exit(true);

    if c < 0 then begin
      lo := mid + 1;
    end else begin
      hi := mid - 1;
    end;
  end;

  result := false;
end;

function FindRule(const ID: string): Integer;
var
  lo, hi, mid, c: Integer;
begin
  lo := 0;
  hi := High(RuleTable);
  while lo <= hi do begin
    mid := (lo + hi) div 2;
    c := CompareStr(RuleTable[mid].ID, ID);
    if c = 0 then exit(mid);

    if c < 0 then begin
      lo := mid + 1;
    end else begin
      hi := mid - 1;
    end;
  end;

  result := -1;
end;

{ Own rules of abdecker (no official rule set) have IDs starting with AB-. }
function IsOwnRule(const ID: string): Boolean;
begin
  result := Copy(ID, 1, 3) = 'AB-';
end;

{ The rule was applied to this invoice (passed unless it fails, too). Extra:
  applied beyond its rule set. }
procedure Apply(var r: TAbCheckReport; const ID: string; Extra: Boolean = false);
var
  i: Integer;
begin
  i := FindRule(ID);
  if (i < 0) or (i > High(r.Rules)) then exit;
  if r.Rules[i].Status = arsNotApplied then r.Rules[i].Status := arsPassed;
  if Extra then r.Rules[i].Origin := aboExtra;
end;

procedure MarkFailed(var r: TAbCheckReport; const ID: string);
var
  i: Integer;
begin
  i := FindRule(ID);
  if (i < 0) or (i > High(r.Rules)) then exit;
  r.Rules[i].Status := arsFailed;
end;

procedure AddFinding(var r: TAbCheckReport; const ID, Detail: string; Origin: TAbOrigin);
var
  i: Integer;
  sev: TAbSeverity;
  t: string;
begin
  i := FindRule(ID);
  if i >= 0 then begin
    sev := RuleTable[i].Severity;
    t := RuleTable[i].Text;
  end else begin
    sev := abError;
    t := ID;
  end;

  if Detail <> '' then t := t + ' [' + Detail + ']';
  AddMsg(r.Messages, sev, ID, t);
  r.Messages[High(r.Messages)].Origin := Origin;

  case sev of
    abError: Inc(r.Errors);
    abWarning: Inc(r.Warnings);
  end;
end;

{ A rule applied within its rule set: official, unless it is an own AB- rule. }
procedure Fail(var r: TAbCheckReport; const ID: string; const Detail: string = '');
begin
  Apply(r, ID);
  MarkFailed(r, ID);

  if IsOwnRule(ID) then begin
    AddFinding(r, ID, Detail, aboExtra);
  end else begin
    AddFinding(r, ID, Detail, aboOfficial);
  end;
end;

{ An official rule applied beyond its rule set: an additional check. }
procedure FailExtra(var r: TAbCheckReport; const ID: string; const Detail: string = '');
begin
  Apply(r, ID, true);
  MarkFailed(r, ID);
  AddFinding(r, ID, Detail, aboExtra);
end;

{ applies the rule ID: a finding unless Cond holds }
procedure Req(Cond: Boolean; var r: TAbCheckReport; const ID: string; const Detail: string = '');
begin
  Apply(r, ID);
  if not Cond then Fail(r, ID, Detail);
end;

procedure ReqExtra(Cond: Boolean; var r: TAbCheckReport; const ID: string; const Detail: string = '');
begin
  Apply(r, ID, true);
  if not Cond then FailExtra(r, ID, Detail);
end;

procedure AddUnique(var l: TAbStrings; const s: string);
var
  i: Integer;
begin
  for i := 0 to High(l) do begin
    if l[i] = s then exit;
  end;

  SetLength(l, Length(l) + 1);
  l[High(l)] := s;
end;

procedure NotChecked(var r: TAbCheckReport; const s: string);
begin
  AddUnique(r.NotChecked, s);
end;

{ An operand of a calculation is unusable: stay silent, but say so. }
function Usable(const d: TAbDecimal; var r: TAbCheckReport): Boolean;
begin
  result := d.IsUsable;
  if not result then begin
    NotChecked(r, 'Calculations with invalid numbers were skipped');
  end;
end;

function DZero: TAbDecimal;
begin
  result := TAbDecimal.FromInt(0);
end;

function DAbs(const d: TAbDecimal): TAbDecimal;
begin
  result := d;
  result.Text := '';
  if result.Value < 0 then result.Value := -result.Value;
end;

{ A * P / 100, exact as long as it fits }
function PctOf(const a, p: TAbDecimal): TAbDecimal;
begin
  result := a.Mul(p);
  if not result.Valid then exit;

  if result.Scale <= 16 then begin
    Inc(result.Scale, 2);
  end else begin
    result := result.Divide(TAbDecimal.FromInt(100), 18);
  end;
end;

{ |A - B| < Tol (Strict) or <= Tol }
function Near(const a, b, Tol: TAbDecimal; Strict: Boolean): Boolean;
var
  c: Integer;
begin
  c := DAbs(a.Sub(b)).Compare(Tol);

  if Strict then begin
    result := c < 0;
  end else begin
    result := c <= 0;
  end;
end;

function MoreThan2Decimals(const d: TAbDecimal): Boolean;
begin
  result := d.Present and d.Valid and (d.Normalized.Scale > 2);
end;

function IsISODate(const s: string): Boolean;
var
  i: Integer;
begin
  result := false;
  if Length(s) <> 10 then exit;

  for i := 1 to 10 do begin
    if (i = 5) or (i = 8) then begin
      if s[i] <> '-' then exit;
    end else if (s[i] < '0') or (s[i] > '9') then exit;
  end;

  result := true;
end;

function DateBefore(const a, b: string): Boolean;
begin
  result := IsISODate(a) and IsISODate(b) and (CompareStr(a, b) < 0);
end;

function HasAddress(const a: TEInvoiceAddress): Boolean;
begin
  result := (a.Line1 <> '') or (a.Line2 <> '') or (a.Line3 <> '') or (a.City <> '') or
    (a.PostCode <> '') or (a.Subdivision <> '') or (a.Country <> '');
end;

function HasContact(const c: TEInvoiceContact): Boolean;
begin
  result := (c.Name <> '') or (c.Phone <> '') or (c.Email <> '');
end;

function HasParty(const p: TEInvoiceParty): Boolean;
begin
  result := (p.Name <> '') or (p.TradingName <> '') or (Length(p.IDs) > 0) or
    (p.LegalID.Value <> '') or (p.VATID <> '') or (p.TaxNumber <> '') or (p.LegalInfo <> '') or
    (p.ElectronicAddress.Value <> '') or HasAddress(p.Address) or HasContact(p.Contact);
end;

function LineRef(const l: TEInvoiceLine; Index: Integer): string;
begin
  if l.ID <> '' then begin
    result := 'line ' + l.ID;
  end else begin
    result := 'line #' + IntToStr(Index + 1);
  end;
end;

function IsTopLevel(const l: TEInvoiceLine): Boolean;
begin
  result := l.ParentID = '';
end;

function HasCard(const Inv: TEInvoice): Boolean;
begin
  result := (Inv.Payment.CardNumber <> '') or (Inv.Payment.CardHolder <> '');
end;

function IsCII(const Inv: TEInvoice): Boolean;
begin
  result := Inv.Info.Syntax in [eisynCII, eisynZUGFeRD1];
end;

{ Direct debit information (BG-19). In CII the mandate reference sits in the
  payment terms and the creditor identifier in the settlement, so KoSIT
  counts them as well. }
function HasDirectDebit(const Inv: TEInvoice): Boolean;
begin
  result := (Inv.Payment.MandateID <> '') or (Inv.Payment.DebitedAccount <> '') or
    (IsCII(Inv) and (Inv.Payment.CreditorID <> ''));
end;

function MeansCount(const Inv: TEInvoice): Integer;
begin
  result := Length(Inv.Payment.MeansCodes);
end;

{ Payment rules are decidable if all payment means have the same type code:
  then every account, card or mandate belongs to a means of that code. }
function MeansUniform(const Inv: TEInvoice): Boolean;
var
  i: Integer;
begin
  result := MeansCount(Inv) > 0;

  for i := 0 to High(Inv.Payment.MeansCodes) do begin
    if Inv.Payment.MeansCodes[i] <> Inv.Payment.MeansCode then exit(false);
  end;
end;

function IsXRExtension(const Inv: TEInvoice): Boolean;
begin
  result := Pos('#conformant#urn:xeinkauf.de:kosit:extension:xrechnung', Inv.Specification) > 0;
end;

function IsCVD(const Inv: TEInvoice): Boolean;
begin
  result := Pos('urn:xeinkauf.de:kosit:xrechnung:cvd', Inv.Specification) > 0;
end;

function CiiSubLines(const Inv: TEInvoice): Boolean;
var
  i: Integer;
begin
  result := false;

  if IsCII(Inv) then begin
    for i := 0 to High(Inv.Lines) do begin
      if Inv.Lines[i].ParentID <> '' then exit(true);
    end;
  end;
end;

{ ===========================================================================
  EN 16931: mandatory content
  =========================================================================== }

procedure CheckMandatory(const Inv: TEInvoice; var r: TAbCheckReport);
var
  i, j: Integer;
  l: TEInvoiceLine;
  ac: TEInvoiceAllowanceCharge;
  ref: string;
  found, reason: Boolean;
begin
  Req(Inv.Specification <> '', r, 'BR-01');
  Req(Inv.Number <> '', r, 'BR-02');
  Req(Inv.IssueDate <> '', r, 'BR-03');
  Req(Inv.TypeCode <> '', r, 'BR-04');
  Req(Inv.Currency <> '', r, 'BR-05');
  Req(Inv.Seller.Name <> '', r, 'BR-06');
  Req(Inv.Buyer.Name <> '', r, 'BR-07');

  Req(HasAddress(Inv.Seller.Address), r, 'BR-08');

  if HasAddress(Inv.Seller.Address) then begin
    Req(Inv.Seller.Address.Country <> '', r, 'BR-09');
  end;

  Req(HasAddress(Inv.Buyer.Address), r, 'BR-10');

  if HasAddress(Inv.Buyer.Address) then begin
    Req(Inv.Buyer.Address.Country <> '', r, 'BR-11');
  end;

  Req(Inv.Totals.LineTotal.Present, r, 'BR-12');
  Req(Inv.Totals.TaxExclusive.Present, r, 'BR-13');
  Req(Inv.Totals.TaxInclusive.Present, r, 'BR-14');
  Req(Inv.Totals.DuePayable.Present, r, 'BR-15');
  Req(Length(Inv.Lines) > 0, r, 'BR-16');

  if HasParty(Inv.Payee) then begin
    Req(Inv.Payee.Name <> '', r, 'BR-17');
  end;

  if HasParty(Inv.TaxRepresentative) then begin
    Req(Inv.TaxRepresentative.Name <> '', r, 'BR-18');

    Req(HasAddress(Inv.TaxRepresentative.Address), r, 'BR-19');

    if HasAddress(Inv.TaxRepresentative.Address) then begin
      Req(Inv.TaxRepresentative.Address.Country <> '', r, 'BR-20');
    end;

    Req(Inv.TaxRepresentative.VATID <> '', r, 'BR-56');
  end;

  if IsISODate(Inv.PeriodStart) and IsISODate(Inv.PeriodEnd) then begin
    Req(not DateBefore(Inv.PeriodEnd, Inv.PeriodStart), r, 'BR-29', Inv.PeriodStart + ' - ' + Inv.PeriodEnd);
  end;

  for i := 0 to High(Inv.Lines) do begin
    l := Inv.Lines[i];
    if not IsTopLevel(l) then continue;
    ref := LineRef(l, i);
    Req(l.ID <> '', r, 'BR-21', ref);
    Req(l.Quantity.Present, r, 'BR-22', ref);
    Req(l.UnitCode <> '', r, 'BR-23', ref);
    Req(l.NetAmount.Present, r, 'BR-24', ref);
    Req(l.ItemName <> '', r, 'BR-25', ref);
    Req(l.NetPrice.Present, r, 'BR-26', ref);

    if l.NetPrice.Present and l.NetPrice.Valid then begin
      Req(l.NetPrice.Sign >= 0, r, 'BR-27', ref);
    end;

    if l.GrossPrice.Present and l.GrossPrice.Valid then begin
      Req(l.GrossPrice.Sign >= 0, r, 'BR-28', ref);
    end;

    if IsISODate(l.PeriodStart) and IsISODate(l.PeriodEnd) then begin
      Req(not DateBefore(l.PeriodEnd, l.PeriodStart), r, 'BR-30', ref);
    end;

    Req(l.TaxCategory <> '', r, 'BR-CO-04', ref);

    if l.StandardItemID.Value <> '' then begin
      Req(l.StandardItemID.Scheme <> '', r, 'BR-64', ref);
    end;

    for j := 0 to High(l.Classifications) do begin
      Req(l.Classifications[j].Scheme <> '', r, 'BR-65', ref);
    end;

    for j := 0 to High(l.AllowancesCharges) do begin
      ac := l.AllowancesCharges[j];
      reason := (ac.Reason <> '') or (ac.ReasonCode <> '');

      if ac.IsCharge then begin
        Req(ac.Amount.Present, r, 'BR-43', ref);
        Req(reason, r, 'BR-44', ref);
        Req(reason, r, 'BR-CO-24', ref);
      end else begin
        Req(ac.Amount.Present, r, 'BR-41', ref);
        Req(reason, r, 'BR-42', ref);
        Req(reason, r, 'BR-CO-23', ref);
      end;
    end;
  end;

  for i := 0 to High(Inv.AllowancesCharges) do begin
    ac := Inv.AllowancesCharges[i];
    reason := (ac.Reason <> '') or (ac.ReasonCode <> '');

    if ac.IsCharge then begin
      Req(ac.Amount.Present, r, 'BR-36');
      Req(ac.TaxCategory <> '', r, 'BR-37');
      Req(reason, r, 'BR-38');
      Req(reason, r, 'BR-CO-22');
    end else begin
      Req(ac.Amount.Present, r, 'BR-31');
      Req(ac.TaxCategory <> '', r, 'BR-32');
      Req(reason, r, 'BR-33');
      Req(reason, r, 'BR-CO-21');
    end;
  end;

  for i := 0 to High(Inv.Taxes) do begin
    Req(Inv.Taxes[i].TaxableAmount.Present, r, 'BR-45');
    Req(Inv.Taxes[i].TaxAmount.Present, r, 'BR-46');
    Req(Inv.Taxes[i].Category <> '', r, 'BR-47');

    if Inv.Taxes[i].Category <> 'O' then begin
      Req(Inv.Taxes[i].Rate.Present, r, 'BR-48', Inv.Taxes[i].Category);
    end;
  end;

  for i := 0 to High(Inv.Payment.MeansCodes) do begin
    Req(Inv.Payment.MeansCodes[i] <> '', r, 'BR-49');
  end;

  for i := 0 to High(Inv.Payment.Accounts) do begin
    Req(Inv.Payment.Accounts[i].IBAN <> '', r, 'BR-50');
  end;

  if Inv.Payment.CardNumber <> '' then begin
    Req(Length(Inv.Payment.CardNumber) <= 10, r, 'BR-51');
  end;

  if ((Inv.Payment.MeansCode = '30') or (Inv.Payment.MeansCode = '58')) and MeansUniform(Inv) then begin
    // at most one account per payment means
    found := Length(Inv.Payment.Accounts) >= MeansCount(Inv);

    for i := 0 to High(Inv.Payment.Accounts) do begin
      if Inv.Payment.Accounts[i].IBAN = '' then found := false;
    end;

    Req(found, r, 'BR-61');
  end;

  for i := 0 to High(Inv.Documents) do begin
    Req(Inv.Documents[i].ID <> '', r, 'BR-52');
  end;

  if Inv.TaxCurrency <> '' then begin
    Req(Inv.Totals.TaxTotalTaxCurrency.Present, r, 'BR-53');
  end;

  for i := 0 to High(Inv.PrecedingInvoices) do begin
    Req(Inv.PrecedingInvoices[i].Number <> '', r, 'BR-55');
  end;

  if HasAddress(Inv.Delivery.Address) then begin
    Req(Inv.Delivery.Address.Country <> '', r, 'BR-57');
  end;

  if Inv.Seller.ElectronicAddress.Value <> '' then begin
    Req(Inv.Seller.ElectronicAddress.Scheme <> '', r, 'BR-62');
  end;

  if Inv.Buyer.ElectronicAddress.Value <> '' then begin
    Req(Inv.Buyer.ElectronicAddress.Scheme <> '', r, 'BR-63');
  end;

  Req((Length(Inv.Seller.IDs) > 0) or (Inv.Seller.LegalID.Value <> '') or (Inv.Seller.VATID <> ''),
    r, 'BR-CO-26');

  if (Inv.TaxPointDate <> '') or (Inv.TaxPointDateCode <> '') then begin
    Req((Inv.TaxPointDate = '') or (Inv.TaxPointDateCode = ''), r, 'BR-CO-03');
  end;
end;

{ ===========================================================================
  EN 16931: totals and VAT calculation
  =========================================================================== }

procedure CheckVatId(var r: TAbCheckReport; const VATID: string);
var
  p: string;
begin
  if VATID = '' then exit;
  p := Copy(VATID, 1, 2);
  Req(InList(CL_VAT_PREFIX, p) or (p = 'EL'), r, 'BR-CO-09', VATID);
end;

procedure CheckTotals(const Inv: TEInvoice; var r: TAbCheckReport);
var
  checkCO13: Boolean;
  checkCO15: Boolean;
  incomplete: Boolean;
  t: TEInvoiceTotals;
  sum, allow, charge, exp, taxes: TAbDecimal;
  ok, anyAllow, anyCharge: Boolean;
  i: Integer;
  x: TEInvoiceTax;
begin
  t := Inv.Totals;

  // BR-CO-10: line total
  if CiiSubLines(Inv) then begin
    NotChecked(r, 'Sums over sub-lines (CII with ParentLineID)');
  end else if t.LineTotal.Present and Usable(t.LineTotal, r) and (Length(Inv.Lines) > 0) then begin
    sum := DZero;
    ok := true;

    for i := 0 to High(Inv.Lines) do begin
      if IsTopLevel(Inv.Lines[i]) then begin
        ok := ok and Usable(Inv.Lines[i].NetAmount, r);
        sum := sum.Add(Inv.Lines[i].NetAmount);
      end;
    end;

    if ok then begin
      Req(t.LineTotal.Equals(sum.Rounded(2)), r, 'BR-CO-10', 'BT-106 = ' + t.LineTotal.ToString + ', sum = ' + sum.ToString);
    end;
  end;

  // BR-CO-11/12: allowance and charge totals
  allow := DZero;
  charge := DZero;
  anyAllow := false;
  anyCharge := false;
  ok := true;

  for i := 0 to High(Inv.AllowancesCharges) do begin
    ok := ok and Usable(Inv.AllowancesCharges[i].Amount, r);

    if Inv.AllowancesCharges[i].IsCharge then begin
      anyCharge := true;
      charge := charge.Add(Inv.AllowancesCharges[i].Amount);
    end else begin
      anyAllow := true;
      allow := allow.Add(Inv.AllowancesCharges[i].Amount);
    end;
  end;

  if ok then begin
    if t.AllowanceTotal.Present then begin
      if Usable(t.AllowanceTotal, r) then begin
        Req(t.AllowanceTotal.Equals(allow.Rounded(2)), r, 'BR-CO-11',
          'BT-107 = ' + t.AllowanceTotal.ToString + ', sum = ' + allow.ToString);
      end;
    end else if anyAllow then begin
      Fail(r, 'BR-CO-11', 'BT-107 missing');
    end;

    if t.ChargeTotal.Present then begin
      if Usable(t.ChargeTotal, r) then begin
        Req(t.ChargeTotal.Equals(charge.Rounded(2)), r, 'BR-CO-12',
          'BT-108 = ' + t.ChargeTotal.ToString + ', sum = ' + charge.ToString);
      end;
    end else if anyCharge then begin
      Fail(r, 'BR-CO-12', 'BT-108 missing');
    end;
  end;

  // BR-CO-13: total without VAT
  checkCO13 := t.TaxExclusive.Present and t.LineTotal.Present and Usable(t.TaxExclusive, r) and
    Usable(t.LineTotal, r) and Usable(t.AllowanceTotal, r) and Usable(t.ChargeTotal, r);

  if checkCO13 then begin
    exp := t.LineTotal.Sub(t.AllowanceTotal).Add(t.ChargeTotal).Rounded(2);
    Req(t.TaxExclusive.Equals(exp), r, 'BR-CO-13', 'BT-109 = ' + t.TaxExclusive.ToString + ', expected ' + exp.ToString);
  end;

  // BR-CO-14: VAT total = sum of the breakdown
  if t.TaxTotal.Present and Usable(t.TaxTotal, r) and (Length(Inv.Taxes) > 0) then begin
    taxes := DZero;
    ok := true;

    for i := 0 to High(Inv.Taxes) do begin
      ok := ok and Usable(Inv.Taxes[i].TaxAmount, r);
      taxes := taxes.Add(Inv.Taxes[i].TaxAmount);
    end;

    if ok then begin
      Req(t.TaxTotal.Equals(taxes.Rounded(2)), r, 'BR-CO-14', 'BT-110 = ' + t.TaxTotal.ToString + ', sum = ' + taxes.ToString);
    end;
  end;

  // BR-CO-15: total with VAT
  checkCO15 := t.TaxInclusive.Present and t.TaxExclusive.Present and Usable(t.TaxInclusive, r) and
    Usable(t.TaxExclusive, r) and Usable(t.TaxTotal, r);

  if checkCO15 then begin
    exp := t.TaxExclusive.Add(t.TaxTotal).Rounded(2);
    Req(t.TaxInclusive.Equals(exp), r, 'BR-CO-15', 'BT-112 = ' + t.TaxInclusive.ToString + ', expected ' + exp.ToString);
  end;

  // BR-CO-16: amount due (the XRechnung extension adds third party payments)
  if IsXRExtension(Inv) then begin
    NotChecked(r, 'Amount due (BT-115) with third party payments (XRechnung extension)');
  end else if t.DuePayable.Present and t.TaxInclusive.Present and Usable(t.DuePayable, r) and
    Usable(t.TaxInclusive, r) and Usable(t.Prepaid, r) and Usable(t.Rounding, r) then
  begin
    exp := t.TaxInclusive.Sub(t.Prepaid).Add(t.Rounding).Rounded(2);
    Req(t.DuePayable.Equals(exp), r, 'BR-CO-16', 'BT-115 = ' + t.DuePayable.ToString + ', expected ' + exp.ToString);
  end;

  // BR-CO-17: VAT amount per breakdown, tolerance below 1 like the official rule
  for i := 0 to High(Inv.Taxes) do begin
    x := Inv.Taxes[i];
    incomplete := not (x.TaxAmount.Present and Usable(x.TaxAmount, r) and Usable(x.TaxableAmount, r) and
      Usable(x.Rate, r));
    if incomplete then continue;

    if not x.Rate.Present or x.Rate.Rounded(0).IsZero then begin
      ok := x.TaxAmount.Rounded(0).IsZero;
    end else begin
      exp := PctOf(DAbs(x.TaxableAmount), x.Rate).Rounded(2);
      ok := exp.Valid and Near(DAbs(x.TaxAmount), exp, TAbDecimal.FromInt(1), true);
    end;

    Req(ok, r, 'BR-CO-17', x.Category + ' ' + x.Rate.ToString + '%: ' + x.TaxAmount.ToString);
  end;

  Req(Length(Inv.Taxes) > 0, r, 'BR-CO-18');

  CheckVatId(r, Inv.Seller.VATID);
  CheckVatId(r, Inv.Buyer.VATID);
  CheckVatId(r, Inv.TaxRepresentative.VATID);
end;

{ ===========================================================================
  EN 16931: decimals
  =========================================================================== }

procedure Dec2(var r: TAbCheckReport; const d: TAbDecimal; const ID: string; const Ref: string = '');
var
  detail: string;
begin
  if not (d.Present and d.Valid) then exit;
  detail := d.Text;
  if Ref <> '' then detail := Ref + ': ' + d.Text;
  Req(not MoreThan2Decimals(d), r, ID, detail);
end;

procedure CheckDecimals(const Inv: TEInvoice; var r: TAbCheckReport);
var
  i, j: Integer;
  ac: TEInvoiceAllowanceCharge;
  l: TEInvoiceLine;
begin
  for i := 0 to High(Inv.AllowancesCharges) do begin
    ac := Inv.AllowancesCharges[i];
    if ac.IsCharge then begin
      Dec2(r, ac.Amount, 'BR-DEC-05');
      Dec2(r, ac.BaseAmount, 'BR-DEC-06');
    end else begin
      Dec2(r, ac.Amount, 'BR-DEC-01');
      Dec2(r, ac.BaseAmount, 'BR-DEC-02');
    end;
  end;

  Dec2(r, Inv.Totals.LineTotal, 'BR-DEC-09');
  Dec2(r, Inv.Totals.AllowanceTotal, 'BR-DEC-10');
  Dec2(r, Inv.Totals.ChargeTotal, 'BR-DEC-11');
  Dec2(r, Inv.Totals.TaxExclusive, 'BR-DEC-12');
  Dec2(r, Inv.Totals.TaxTotal, 'BR-DEC-13');
  Dec2(r, Inv.Totals.TaxInclusive, 'BR-DEC-14');
  Dec2(r, Inv.Totals.TaxTotalTaxCurrency, 'BR-DEC-15');
  Dec2(r, Inv.Totals.Prepaid, 'BR-DEC-16');
  Dec2(r, Inv.Totals.Rounding, 'BR-DEC-17');
  Dec2(r, Inv.Totals.DuePayable, 'BR-DEC-18');

  for i := 0 to High(Inv.Taxes) do begin
    Dec2(r, Inv.Taxes[i].TaxableAmount, 'BR-DEC-19');
    Dec2(r, Inv.Taxes[i].TaxAmount, 'BR-DEC-20');
  end;

  for i := 0 to High(Inv.Lines) do begin
    l := Inv.Lines[i];
    if not IsTopLevel(l) then continue;
    Dec2(r, l.NetAmount, 'BR-DEC-23', LineRef(l, i));

    for j := 0 to High(l.AllowancesCharges) do begin
      ac := l.AllowancesCharges[j];
      if ac.IsCharge then begin
        Dec2(r, ac.Amount, 'BR-DEC-27', LineRef(l, i));
        Dec2(r, ac.BaseAmount, 'BR-DEC-28', LineRef(l, i));
      end else begin
        Dec2(r, ac.Amount, 'BR-DEC-24', LineRef(l, i));
        Dec2(r, ac.BaseAmount, 'BR-DEC-25', LineRef(l, i));
      end;
    end;
  end;
end;

{ ===========================================================================
  EN 16931: code lists
  =========================================================================== }

procedure Code(var r: TAbCheckReport; const l: array of string; const Value, ID: string;
  const Ref: string = ''; const Extra: string = '');
var
  known: Boolean;
  detail: string;
begin
  if Value = '' then exit;
  known := InList(l, Value) or ((Extra <> '') and (Pos(' ' + Value + ' ', Extra) > 0));
  detail := Value;
  if Ref <> '' then detail := Ref + ': ' + Value;
  Req(known, r, ID, detail);
end;

procedure CheckPartyCodes(var r: TAbCheckReport; const p: TEInvoiceParty; const Ext: string);
var
  i: Integer;
begin
  for i := 0 to High(p.IDs) do begin
    Code(r, CL_ISO6523, p.IDs[i].Scheme, 'BR-CL-10', '', Ext);
  end;

  Code(r, CL_ISO6523, p.LegalID.Scheme, 'BR-CL-11', '', Ext);
  Code(r, CL_ISO3166, p.Address.Country, 'BR-CL-14');
  Code(r, CL_EAS, p.ElectronicAddress.Scheme, 'BR-CL-25', '', Ext);
end;

procedure CheckCodes(const Inv: TEInvoice; var r: TAbCheckReport);
var
  i, j: Integer;
  l: TEInvoiceLine;
  ac: TEInvoiceAllowanceCharge;
  ext, cvd: string;
begin
  // the XRechnung extension allows additional schemes, CVD an additional classification
  ext := '';
  if IsXRExtension(Inv) then ext := ' XR01 XR02 XR03 ';
  cvd := '';
  if IsCVD(Inv) then cvd := ' CVD ';

  case Inv.Info.Syntax of
    eisynUBLInvoice: Code(r, CL_UNTDID1001_INVOICE, Inv.TypeCode, 'BR-CL-01');
    eisynUBLCreditNote: Code(r, CL_UNTDID1001_CREDITNOTE, Inv.TypeCode, 'BR-CL-01');
  else
    Code(r, CL_UNTDID1001_CII, Inv.TypeCode, 'BR-CL-01');
  end;

  Code(r, CL_ISO4217, Inv.Currency, 'BR-CL-04');
  Code(r, CL_ISO4217, Inv.TaxCurrency, 'BR-CL-05');
  Code(r, CL_UNTDID2005, Inv.TaxPointDateCode, 'BR-CL-06');
  Code(r, CL_UNTDID1153, Inv.InvoicedObject.Scheme, 'BR-CL-07');

  for i := 0 to High(Inv.Notes) do begin
    Code(r, CL_UNTDID4451, Inv.Notes[i].SubjectCode, 'BR-CL-08');
  end;

  CheckPartyCodes(r, Inv.Seller, ext);
  CheckPartyCodes(r, Inv.Buyer, ext);
  CheckPartyCodes(r, Inv.Payee, ext);
  CheckPartyCodes(r, Inv.TaxRepresentative, ext);
  Code(r, CL_ISO3166, Inv.Delivery.Address.Country, 'BR-CL-14');
  Code(r, CL_ISO6523, Inv.Delivery.LocationID.Scheme, 'BR-CL-26', '', ext);
  Code(r, CL_UNTDID4461, Inv.Payment.MeansCode, 'BR-CL-16');

  for i := 0 to High(Inv.Taxes) do begin
    Code(r, CL_UNTDID5305, Inv.Taxes[i].Category, 'BR-CL-17');
    Code(r, CL_VATEX, UpperCase(Inv.Taxes[i].ExemptionReasonCode), 'BR-CL-22');
  end;

  for i := 0 to High(Inv.AllowancesCharges) do begin
    ac := Inv.AllowancesCharges[i];
    Code(r, CL_UNTDID5305, ac.TaxCategory, 'BR-CL-17');

    if ac.IsCharge then begin
      Code(r, CL_UNTDID7161, ac.ReasonCode, 'BR-CL-20');
    end else begin
      Code(r, CL_UNTDID5189, ac.ReasonCode, 'BR-CL-19');
    end;
  end;

  for i := 0 to High(Inv.Documents) do begin
    Code(r, CL_MIME, Inv.Documents[i].MimeType, 'BR-CL-24');
  end;

  for i := 0 to High(Inv.Lines) do begin
    l := Inv.Lines[i];
    if not IsTopLevel(l) then continue;
    Code(r, CL_UNTDID1153, l.ObjectID.Scheme, 'BR-CL-07', LineRef(l, i));

    for j := 0 to High(l.Classifications) do begin
      Code(r, CL_UNTDID7143, l.Classifications[j].Scheme, 'BR-CL-13', LineRef(l, i), cvd);
    end;

    Code(r, CL_ISO3166, l.OriginCountry, 'BR-CL-15', LineRef(l, i));
    Code(r, CL_UNTDID5305, l.TaxCategory, 'BR-CL-18', LineRef(l, i));
    Code(r, CL_ISO6523, l.StandardItemID.Scheme, 'BR-CL-21', LineRef(l, i), ext);
    Code(r, CL_UNECE_REC20, l.UnitCode, 'BR-CL-23', LineRef(l, i));
    Code(r, CL_UNECE_REC20, l.BaseQuantityUnit, 'BR-CL-23', LineRef(l, i));

    for j := 0 to High(l.AllowancesCharges) do begin
      if l.AllowancesCharges[j].IsCharge then begin
        Code(r, CL_UNTDID7161, l.AllowancesCharges[j].ReasonCode, 'BR-CL-20', LineRef(l, i));
      end else begin
        Code(r, CL_UNTDID5189, l.AllowancesCharges[j].ReasonCode, 'BR-CL-19', LineRef(l, i));
      end;
    end;
  end;
end;

{ ===========================================================================
  EN 16931: VAT categories (BR-S, -Z, -E, -AE, -IC, -G, -O, -IG, -IP)

  All nine rule blocks share one pattern; the differences are parameters.
  =========================================================================== }

const
  // rate of lines, allowances and charges
  RateAboveZero = 1;
  RateZero = 2;
  RateNone = 3;
  RateZeroOrMore = 4;
  // identifiers required (-02..-04)
  IdSellerVatOrTax = 1;   // S, Z, E, L, M
  IdReverseCharge = 2;    // AE
  IdIntraCommunity = 3;   // K
  IdExport = 4;           // G
  IdNoVat = 5;            // O
  // VAT breakdown required (-01)
  BdBoth = 1;             // S: used <=> breakdown exists
  BdExactlyOne = 2;
  BdAtLeastOne = 3;

function RateOK(const d: TAbDecimal; Mode: Integer): Boolean;
begin
  case Mode of
    RateAboveZero: result := d.Present and d.Valid and (d.Sign > 0);
    RateZero: result := d.Present and d.Valid and d.IsZero;
    RateNone: result := not d.Present;
    RateZeroOrMore: result := d.Present and d.Valid and (d.Sign >= 0);
  else
    result := true;
  end;
end;

procedure CheckCategory(const Inv: TEInvoice; var r: TAbCheckReport; const Cat, p: string;
  RateMode, IdMode, BdMode: Integer; PerRate, ReasonRequired: Boolean);
var
  rateKnown: Boolean;
  used: Boolean;
  other: string;
  lineCounts: Boolean;
  acCounts: Boolean;
  i, j, nBd: Integer;
  usedLine, usedAllow, usedCharge, idOK, sellerVatOrTax, repVat, ok, exists: Boolean;
  l: TEInvoiceLine;
  ac: TEInvoiceAllowanceCharge;
  x: TEInvoiceTax;
  sum, exp: TAbDecimal;
begin
  usedLine := false;
  usedAllow := false;
  usedCharge := false;

  for i := 0 to High(Inv.Lines) do begin
    if Inv.Lines[i].TaxCategory = Cat then usedLine := true;
  end;

  for i := 0 to High(Inv.AllowancesCharges) do begin
    if Inv.AllowancesCharges[i].TaxCategory = Cat then begin
      if Inv.AllowancesCharges[i].IsCharge then begin
        usedCharge := true;
      end else begin
        usedAllow := true;
      end;
    end;
  end;

  nBd := 0;

  for i := 0 to High(Inv.Taxes) do begin
    if Inv.Taxes[i].Category = Cat then Inc(nBd);
  end;

  // -01 VAT breakdown for the category
  used := usedLine or usedAllow or usedCharge;

  case BdMode of
    BdBoth:
      if used or (nBd > 0) then Req(used = (nBd > 0), r, p + '-01');
    BdExactlyOne:
      if used or (nBd > 0) then Req(nBd = 1, r, p + '-01');
    BdAtLeastOne:
      if used then Req(nBd > 0, r, p + '-01');
  end;

  // -02..-04 identifiers
  sellerVatOrTax := (Inv.Seller.VATID <> '') or (Inv.Seller.TaxNumber <> '');
  repVat := Inv.TaxRepresentative.VATID <> '';

  case IdMode of
    IdSellerVatOrTax: idOK := sellerVatOrTax or repVat;
    IdReverseCharge: idOK := (sellerVatOrTax or repVat) and
      ((Inv.Buyer.VATID <> '') or (Inv.Buyer.LegalID.Value <> ''));
    IdIntraCommunity: idOK := ((Inv.Seller.VATID <> '') or repVat) and (Inv.Buyer.VATID <> '');
    IdExport: idOK := (Inv.Seller.VATID <> '') or repVat;
    IdNoVat: idOK := not ((Inv.Seller.VATID <> '') or repVat or (Inv.Buyer.VATID <> ''));
  else
    idOK := true;
  end;

  if usedLine then Req(idOK, r, p + '-02');
  if usedAllow then Req(idOK, r, p + '-03');
  if usedCharge then Req(idOK, r, p + '-04');

  // -05..-07 rates
  for i := 0 to High(Inv.Lines) do begin
    l := Inv.Lines[i];
    if IsTopLevel(l) and (l.TaxCategory = Cat) and (l.TaxRate.Valid or not l.TaxRate.Present) then begin
      Req(RateOK(l.TaxRate, RateMode), r, p + '-05', LineRef(l, i));
    end;
  end;

  for i := 0 to High(Inv.AllowancesCharges) do begin
    ac := Inv.AllowancesCharges[i];
    rateKnown := (ac.TaxCategory = Cat) and (ac.TaxRate.Valid or not ac.TaxRate.Present);

    if rateKnown then begin
      if ac.IsCharge then begin
        Req(RateOK(ac.TaxRate, RateMode), r, p + '-07');
      end else begin
        Req(RateOK(ac.TaxRate, RateMode), r, p + '-06');
      end;
    end;
  end;

  // -08..-10 per VAT breakdown of the category
  for i := 0 to High(Inv.Taxes) do begin
    x := Inv.Taxes[i];
    if x.Category <> Cat then continue;

    // -08 taxable amount
    if CiiSubLines(Inv) then begin
      NotChecked(r, 'Sums over sub-lines (CII with ParentLineID)');
    end else if x.TaxableAmount.Present and Usable(x.TaxableAmount, r) and
      (not PerRate or (x.Rate.Present and Usable(x.Rate, r))) then
    begin
      sum := DZero;
      ok := true;
      exists := false;

      for j := 0 to High(Inv.Lines) do begin
        l := Inv.Lines[j];
        lineCounts := IsTopLevel(l) and (l.TaxCategory = Cat) and
          (not PerRate or (l.TaxRate.Valid and l.TaxRate.Equals(x.Rate)));

        if lineCounts then begin
          exists := true;
          ok := ok and Usable(l.NetAmount, r);
          sum := sum.Add(l.NetAmount);
        end;
      end;

      for j := 0 to High(Inv.AllowancesCharges) do begin
        ac := Inv.AllowancesCharges[j];
        acCounts := (ac.TaxCategory = Cat) and
          (not PerRate or (ac.TaxRate.Valid and ac.TaxRate.Equals(x.Rate)));

        if acCounts then begin
          exists := true;
          ok := ok and Usable(ac.Amount, r);

          if ac.IsCharge then begin
            sum := sum.Add(ac.Amount);
          end else begin
            sum := sum.Sub(ac.Amount);
          end;
        end;
      end;

      if ok then begin
        if PerRate then begin
          ok := exists and Near(x.TaxableAmount, sum, TAbDecimal.FromInt(1), true);
        end else begin
          ok := x.TaxableAmount.Equals(sum);
        end;

        Req(ok, r, p + '-08', 'BT-116 = ' + x.TaxableAmount.ToString + ', expected ' + sum.ToString);
      end;
    end;

    // -09 tax amount
    if x.TaxAmount.Present and Usable(x.TaxAmount, r) then begin
      if PerRate then begin
        if x.Rate.Present and Usable(x.Rate, r) and Usable(x.TaxableAmount, r) then begin
          exp := PctOf(DAbs(x.TaxableAmount), x.Rate).Rounded(2);
          Req(exp.Valid and Near(DAbs(x.TaxAmount), exp, TAbDecimal.FromInt(1), true), r, p + '-09',
            'BT-117 = ' + x.TaxAmount.ToString + ', expected ' + exp.ToString);
        end;
      end else begin
        Req(x.TaxAmount.IsZero, r, p + '-09', 'BT-117 = ' + x.TaxAmount.ToString);
      end;
    end;

    // -10 exemption reason
    if ReasonRequired then begin
      Req((x.ExemptionReason <> '') or (x.ExemptionReasonCode <> ''), r, p + '-10');
    end else begin
      Req((x.ExemptionReason = '') and (x.ExemptionReasonCode = ''), r, p + '-10');
    end;
  end;

  // category specific extras
  if (Cat = 'K') and (nBd > 0) then begin
    Req((Inv.Delivery.Date <> '') or (Inv.PeriodStart <> '') or (Inv.PeriodEnd <> '') or
      (Inv.TaxPointDateCode <> ''), r, 'BR-IC-11');
    Req(Inv.Delivery.Address.Country <> '', r, 'BR-IC-12');
  end;

  if (Cat = 'O') and (nBd > 0) then begin
    other := '';

    for i := 0 to High(Inv.Taxes) do begin
      if Inv.Taxes[i].Category <> 'O' then begin
        other := Inv.Taxes[i].Category;
        break;
      end;
    end;

    Req(other = '', r, 'BR-O-11', other);

    for i := 0 to High(Inv.Lines) do begin
      Req(Inv.Lines[i].TaxCategory = 'O', r, 'BR-O-12', LineRef(Inv.Lines[i], i));
    end;

    for i := 0 to High(Inv.AllowancesCharges) do begin
      if Inv.AllowancesCharges[i].IsCharge then begin
        Req(Inv.AllowancesCharges[i].TaxCategory = 'O', r, 'BR-O-14');
      end else begin
        Req(Inv.AllowancesCharges[i].TaxCategory = 'O', r, 'BR-O-13');
      end;
    end;
  end;
end;

procedure CheckVat(const Inv: TEInvoice; var r: TAbCheckReport);
var
  i: Integer;
  usedB: Boolean;
begin
  CheckCategory(Inv, r, 'S', 'BR-S', RateAboveZero, IdSellerVatOrTax, BdBoth, true, false);
  CheckCategory(Inv, r, 'Z', 'BR-Z', RateZero, IdSellerVatOrTax, BdExactlyOne, false, false);
  CheckCategory(Inv, r, 'E', 'BR-E', RateZero, IdSellerVatOrTax, BdExactlyOne, false, true);
  CheckCategory(Inv, r, 'AE', 'BR-AE', RateZero, IdReverseCharge, BdExactlyOne, false, true);
  CheckCategory(Inv, r, 'K', 'BR-IC', RateZero, IdIntraCommunity, BdExactlyOne, false, true);
  CheckCategory(Inv, r, 'G', 'BR-G', RateZero, IdExport, BdExactlyOne, false, true);
  CheckCategory(Inv, r, 'O', 'BR-O', RateNone, IdNoVat, BdExactlyOne, false, true);
  CheckCategory(Inv, r, 'L', 'BR-IG', RateZeroOrMore, IdSellerVatOrTax, BdAtLeastOne, true, false);
  CheckCategory(Inv, r, 'M', 'BR-IP', RateZeroOrMore, IdSellerVatOrTax, BdAtLeastOne, true, false);
  usedB := false;

  for i := 0 to High(Inv.Taxes) do begin
    if Inv.Taxes[i].Category = 'B' then usedB := true;
  end;

  for i := 0 to High(Inv.Lines) do begin
    if Inv.Lines[i].TaxCategory = 'B' then usedB := true;
  end;

  if usedB then begin
    NotChecked(r, 'VAT category B (split payment, Italy)');
  end;
end;

{ ===========================================================================
  XRechnung 3.0 (KoSIT) and the Peppol rules it applies
  =========================================================================== }

{ IBAN check as in the XRechnung schematron (structure + mod 97) }
function CheckIBAN(const s: string): Boolean;
var
  t, re: string;
  i, m, v: Integer;
  c: Char;
begin
  t := '';

  for i := 1 to Length(s) do begin
    if s[i] > ' ' then t := t + s[i];
  end;

  result := false;
  if (Length(t) < 4) or (Length(t) > 34) then exit;

  for i := 1 to Length(t) do begin
    c := t[i];

    if i <= 2 then begin
      if (c < 'A') or (c > 'Z') then exit;
    end else if i <= 4 then begin
      if (c < '0') or (c > '9') then exit;
    end else if not (((c >= 'A') and (c <= 'Z')) or ((c >= 'a') and (c <= 'z')) or ((c >= '0') and (c <= '9'))) then begin
      exit;
    end;
  end;

  re := Copy(t, 5, MaxInt) + UpperCase(Copy(t, 1, 2)) + Copy(t, 3, 2);
  m := 0;

  for i := 1 to Length(re) do begin
    if Ord(re[i]) > 64 then begin
      v := Ord(re[i]) - 55;
    end else begin
      v := Ord(re[i]) - 48;
    end;

    if v >= 10 then begin
      m := (m * 100 + v) mod 97;
    end else begin
      m := (m * 10 + v) mod 97;
    end;
  end;

  result := m = 1;
end;

function CountDigits(const s: string): Integer;
var
  i: Integer;
begin
  result := 0;

  for i := 1 to Length(s) do begin
    if (s[i] >= '0') and (s[i] <= '9') then Inc(result);
  end;
end;

{ ^[^@\s]+@([^@.\s]+\.)+[^@.\s]+$ }
function EmailOK(const s: string): Boolean;
var
  i, at, labels, len: Integer;
begin
  result := false;
  at := Pos('@', s);
  if at <= 1 then exit;

  for i := 1 to Length(s) do begin
    if s[i] <= ' ' then exit;
  end;

  if Pos('@', Copy(s, at + 1, MaxInt)) > 0 then exit;
  labels := 0;
  len := 0;

  for i := at + 1 to Length(s) do begin
    if s[i] = '.' then begin
      if len = 0 then exit;
      Inc(labels);
      len := 0;
    end else begin
      Inc(len);
    end;
  end;

  result := (labels >= 1) and (len > 0);
end;

function CollapseSpaces(const s: string): string;
var
  i: Integer;
  space: Boolean;
begin
  result := '';
  space := false;

  for i := 1 to Length(s) do begin
    if s[i] <= ' ' then begin
      space := result <> '';
    end else begin
      if space then result := result + ' ';
      space := false;
      result := result + s[i];
    end;
  end;
end;

{ #SKONTO#TAGE=n#PROZENT=n.nn(#BASISBETRAG=-n.nn)?# }
function SkontoLineOK(const s: string): Boolean;
var
  p: Integer;

  function Lit(const t: string): Boolean;
  begin
    result := Copy(s, p, Length(t)) = t;
    if result then Inc(p, Length(t));
  end;

  function Digits(Min, Max: Integer): Boolean;
  var
    n: Integer;
  begin
    n := 0;
    while (p <= Length(s)) and (s[p] >= '0') and (s[p] <= '9') and ((Max = 0) or (n < Max)) do begin
      Inc(p);
      Inc(n);
    end;

    result := n >= Min;
  end;

begin
  p := 1;
  result := Lit('#SKONTO#TAGE=') and Digits(1, 0) and Lit('#PROZENT=') and Digits(1, 0) and
    Lit('.') and Digits(2, 2);
  if not result then exit;

  if Lit('#BASISBETRAG=') then begin
    Lit('-');
    result := Digits(1, 0) and Lit('.') and Digits(2, 2);
    if not result then exit;
  end;

  result := Lit('#') and (p = Length(s) + 1);
end;

{ BR-DE-18: every line starting with '#' must be a valid Skonto line, and the
  text after the last '#...#' must start with optional whitespace + newline. }
function SkontoOK(const Terms: string): Boolean;
var
  lines: TAbStrings;
  i, start, lastHashLine, k: Integer;
  s, rest: string;
  anyHash: Boolean;
begin
  result := true;
  lines := nil;
  start := 1;

  for i := 1 to Length(Terms) + 1 do begin
    if (i > Length(Terms)) or (Terms[i] = #10) then begin
      SetLength(lines, Length(lines) + 1);
      lines[High(lines)] := Copy(Terms, start, i - start);
      start := i + 1;
    end;
  end;

  anyHash := false;

  for i := 0 to High(lines) do begin
    s := CollapseSpaces(lines[i]);
    if (s <> '') and (s[1] = '#') then begin
      anyHash := true;
      if not SkontoLineOK(s) then exit(false);
    end;
  end;

  if not anyHash then exit;
  // the last line with at least two '#' is the end of the Skonto block
  lastHashLine := -1;

  for i := 0 to High(lines) do begin
    s := lines[i];
    k := Pos('#', s);
    if (k > 0) and (Pos('#', Copy(s, k + 1, MaxInt)) > 0) then lastHashLine := i;
  end;

  if lastHashLine < 0 then exit;
  s := lines[lastHashLine];
  k := Length(s);
  while (k > 0) and (s[k] <> '#') do begin
    Dec(k);
  end;

  rest := Copy(s, k + 1, MaxInt);
  // something must follow on a next line break: only whitespace up to it
  if Trim(rest) <> '' then exit(false);
  result := lastHashLine < High(lines);
end;

function UsesVatCodes(const Inv: TEInvoice): Boolean;
const
  Codes: array[0..7] of string = ('AE', 'E', 'G', 'K', 'L', 'M', 'S', 'Z');
var
  i: Integer;
begin
  result := false;

  for i := 0 to High(Inv.Lines) do begin
    if InList(Codes, Inv.Lines[i].TaxCategory) then exit(true);
  end;

  for i := 0 to High(Inv.AllowancesCharges) do begin
    if InList(Codes, Inv.AllowancesCharges[i].TaxCategory) then exit(true);
  end;
end;

{ Rounding tolerance of the Peppol calculation rules (R040, R120). }
function RoundingSlack(const Inv: TEInvoice): TAbDecimal;
begin
  if Inv.Currency = 'HUF' then begin
    result := TAbDecimal.Parse('0.5');
  end else begin
    result := TAbDecimal.Parse('0.02');
  end;
end;

{ PEPPOL-EN16931-R120: line net amount = quantity x price / base quantity
  + charges - allowances. EN 16931 itself has no such rule; XRechnung 3.0 and
  Peppol BIS adopted it. The formula holds for every EN 16931 invoice, so it
  runs for all profiles, as a warning (severity from data/rules.txt): official
  for XRechnung 3.0 and Peppol, an additional check for everything else. }
procedure CheckLineAmounts(const Inv: TEInvoice; var r: TAbCheckReport);
var
  i, j: Integer;
  l: TEInvoiceLine;
  slack, qty, base, price, allow, charge, exp, net: TAbDecimal;
  ok, official: Boolean;
  detail: string;
begin
  official := (Inv.Info.Profile = eiprofPeppol) or
    ((Inv.Info.Profile = eiprofXRechnung) and (Pos('3.', Inv.Info.XRechnungVersion) = 1));
  slack := RoundingSlack(Inv);

  for i := 0 to High(Inv.Lines) do begin
    l := Inv.Lines[i];
    // a missing amount or price is reported by BR-24/BR-26 already
    if not IsTopLevel(l) or not l.NetAmount.Present or not l.NetPrice.Present then continue;
    ok := Usable(l.NetAmount, r) and Usable(l.Quantity, r) and Usable(l.NetPrice, r) and
      Usable(l.BaseQuantity, r);
    allow := DZero;
    charge := DZero;

    for j := 0 to High(l.AllowancesCharges) do begin
      ok := ok and Usable(l.AllowancesCharges[j].Amount, r);

      if l.AllowancesCharges[j].IsCharge then begin
        charge := charge.Add(l.AllowancesCharges[j].Amount);
      end else begin
        allow := allow.Add(l.AllowancesCharges[j].Amount);
      end;
    end;

    if not ok then continue;
    net := l.NetAmount;

    if l.Quantity.Present then begin
      qty := l.Quantity;
    end else begin
      qty := TAbDecimal.FromInt(1);
    end;

    price := l.NetPrice;

    if l.BaseQuantity.Present and not l.BaseQuantity.IsZero then begin
      base := l.BaseQuantity;
    end else begin
      base := TAbDecimal.FromInt(1);
    end;

    exp := qty.Mul(price.Divide(base, 10)).Add(charge.Rounded(2)).Sub(allow.Rounded(2));
    if not exp.Valid then continue;
    detail := LineRef(l, i) + ': ' + net.ToString + ', expected ' + exp.Rounded(2).ToString;

    if official then begin
      Req(Near(net, exp, slack, false), r, 'PEPPOL-EN16931-R120', detail);
    end else begin
      ReqExtra(Near(net, exp, slack, false), r, 'PEPPOL-EN16931-R120', detail);
    end;
  end;
end;

procedure CheckAllowanceChargePeppol(var r: TAbCheckReport; const AC: TEInvoiceAllowanceCharge;
  const Slack: TAbDecimal; const Ref: string);
var
  canCompute: Boolean;
  exp: TAbDecimal;
begin
  if AC.Percent.Present then Req(AC.BaseAmount.Present, r, 'PEPPOL-EN16931-R041', Ref);
  if AC.BaseAmount.Present then Req(AC.Percent.Present, r, 'PEPPOL-EN16931-R042', Ref);

  canCompute := AC.Percent.Present and AC.BaseAmount.Present and Usable(AC.Percent, r) and
    Usable(AC.BaseAmount, r) and Usable(AC.Amount, r);

  if canCompute then begin
    exp := PctOf(AC.BaseAmount, AC.Percent);

    if exp.Valid then begin
      Req(Near(AC.Amount, exp, Slack, false), r, 'PEPPOL-EN16931-R040',
        Ref + 'amount ' + AC.Amount.ToString + ', expected ' + exp.Rounded(2).ToString);
    end;
  end;
end;

procedure CheckXRechnung(const Inv: TEInvoice; var r: TAbCheckReport);
var
  i, j: Integer;
  l: TEInvoiceLine;
  c: string;
  slack: TAbDecimal;
  one: Boolean;
begin
  // payment instructions
  Req(MeansCount(Inv) > 0, r, 'BR-DE-1');

  // seller
  Req(HasContact(Inv.Seller.Contact), r, 'BR-DE-2');

  if HasContact(Inv.Seller.Contact) then begin
    Req(Inv.Seller.Contact.Name <> '', r, 'BR-DE-5');
    Req(Inv.Seller.Contact.Phone <> '', r, 'BR-DE-6');
    Req(Inv.Seller.Contact.Email <> '', r, 'BR-DE-7');
    Req(CountDigits(Inv.Seller.Contact.Phone) >= 3, r, 'BR-DE-27', Inv.Seller.Contact.Phone);
    Req(EmailOK(Trim(Inv.Seller.Contact.Email)), r, 'BR-DE-28', Inv.Seller.Contact.Email);
  end;

  if HasAddress(Inv.Seller.Address) then begin
    Req(Inv.Seller.Address.City <> '', r, 'BR-DE-3');
    Req(Inv.Seller.Address.PostCode <> '', r, 'BR-DE-4');
  end;

  if HasAddress(Inv.Buyer.Address) then begin
    Req(Inv.Buyer.Address.City <> '', r, 'BR-DE-8');
    Req(Inv.Buyer.Address.PostCode <> '', r, 'BR-DE-9');
  end;

  if HasAddress(Inv.Delivery.Address) then begin
    Req(Inv.Delivery.Address.City <> '', r, 'BR-DE-10');
    Req(Inv.Delivery.Address.PostCode <> '', r, 'BR-DE-11');
  end;

  for i := 0 to High(Inv.Taxes) do begin
    Req(Inv.Taxes[i].Rate.Present, r, 'BR-DE-14', Inv.Taxes[i].Category);
  end;

  Req(Inv.BuyerReference <> '', r, 'BR-DE-15');

  if UsesVatCodes(Inv) then begin
    Req((Inv.Seller.VATID <> '') or (Inv.Seller.TaxNumber <> '') or HasParty(Inv.TaxRepresentative),
      r, 'BR-DE-16');
  end;

  c := Inv.TypeCode;
  Req((c = '326') or (c = '380') or (c = '381') or (c = '384') or (c = '389') or (c = '875') or
    (c = '876') or (c = '877'), r, 'BR-DE-17', c);
  Req(SkontoOK(Inv.PaymentTerms), r, 'BR-DE-18');
  Req((Inv.Specification = XR_CIUS_ID) or (Inv.Specification = XR_EXTENSION_ID) or
    (Inv.Specification = XR_CVD_ID), r, 'BR-DE-21', Inv.Specification);

  if Length(Inv.Documents) > 0 then Apply(r, 'BR-DE-22');

  for i := 0 to High(Inv.Documents) do begin
    for j := 0 to i - 1 do begin
      if (Inv.Documents[i].FileName <> '') and (Inv.Documents[i].FileName = Inv.Documents[j].FileName) then begin
        Fail(r, 'BR-DE-22', Inv.Documents[i].FileName);
      end;
    end;
  end;

  if Inv.TypeCode = '384' then begin
    Req(Length(Inv.PrecedingInvoices) > 0, r, 'BR-DE-26');
  end;

  // payment means: decidable if all of them have the same type code
  one := MeansUniform(Inv);
  if (MeansCount(Inv) > 1) and not one then begin
    NotChecked(r, 'Payment instructions with different type codes: XRechnung payment rules skipped');
  end;

  c := Inv.Payment.MeansCode;
  if one and ((c = '30') or (c = '58')) then begin
    Req(Length(Inv.Payment.Accounts) >= MeansCount(Inv), r, 'BR-DE-23-a');
    Req(not HasCard(Inv) and not HasDirectDebit(Inv), r, 'BR-DE-23-b');

    if c = '58' then begin
      for i := 0 to High(Inv.Payment.Accounts) do begin
        Req(CheckIBAN(Inv.Payment.Accounts[i].IBAN), r, 'BR-DE-19', Inv.Payment.Accounts[i].IBAN);
      end;

      if Length(Inv.Payment.Accounts) < MeansCount(Inv) then begin
        Fail(r, 'BR-DE-19');
      end;
    end;
  end;

  if one and ((c = '48') or (c = '54') or (c = '55')) then begin
    Req(HasCard(Inv), r, 'BR-DE-24-a');
    Req((Length(Inv.Payment.Accounts) = 0) and not HasDirectDebit(Inv), r, 'BR-DE-24-b');
  end;

  if one and (c = '59') then begin
    Req(HasDirectDebit(Inv), r, 'BR-DE-25-a');
    Req((Length(Inv.Payment.Accounts) = 0) and not HasCard(Inv), r, 'BR-DE-25-b');
    Req(CheckIBAN(Inv.Payment.DebitedAccount), r, 'BR-DE-20', Inv.Payment.DebitedAccount);
  end;

  if (Inv.Payment.MandateID <> '') or (Inv.Payment.DebitedAccount <> '') then begin
    Req(Inv.Payment.CreditorID <> '', r, 'BR-DE-30');
  end;

  if (Inv.Payment.MandateID <> '') or (IsCII(Inv) and (Inv.Payment.CreditorID <> '')) then begin
    Req(Inv.Payment.DebitedAccount <> '', r, 'BR-DE-31');
  end;

  // Peppol rules used by XRechnung 3.0
  Req(Inv.BusinessProcess <> '', r, 'PEPPOL-EN16931-R001');

  if Inv.TaxCurrency <> '' then begin
    Req(Inv.TaxCurrency <> Inv.Currency, r, 'PEPPOL-EN16931-R005');
  end;

  Req(Inv.Buyer.ElectronicAddress.Value <> '', r, 'PEPPOL-EN16931-R010');
  Req(Inv.Seller.ElectronicAddress.Value <> '', r, 'PEPPOL-EN16931-R020');

  if (c = '49') or (c = '59') then begin
    if IsCII(Inv) or one then begin
      Req(Inv.Payment.MandateID <> '', r, 'PEPPOL-EN16931-R061');
    end;
  end;

  slack := RoundingSlack(Inv);

  for i := 0 to High(Inv.AllowancesCharges) do begin
    CheckAllowanceChargePeppol(r, Inv.AllowancesCharges[i], slack, '');
  end;

  for i := 0 to High(Inv.Lines) do begin
    l := Inv.Lines[i];
    if not IsTopLevel(l) then continue;

    for j := 0 to High(l.AllowancesCharges) do begin
      CheckAllowanceChargePeppol(r, l.AllowancesCharges[j], slack, LineRef(l, i) + ': ');
    end;

    if IsISODate(l.PeriodStart) and IsISODate(Inv.PeriodStart) then begin
      Req(not DateBefore(l.PeriodStart, Inv.PeriodStart), r, 'PEPPOL-EN16931-R110', LineRef(l, i));
    end;

    if IsISODate(l.PeriodEnd) and IsISODate(Inv.PeriodEnd) then begin
      Req(not DateBefore(Inv.PeriodEnd, l.PeriodEnd), r, 'PEPPOL-EN16931-R111', LineRef(l, i));
    end;

    if l.BaseQuantity.Present and l.BaseQuantity.Valid then begin
      Req(l.BaseQuantity.Sign > 0, r, 'PEPPOL-EN16931-R121', LineRef(l, i));
    end;
  end;
end;

{ ===========================================================================
  Entry point
  =========================================================================== }

function ProfileText(p: TEInvoiceProfile): string;
begin
  result := TAbdecker.ProfileName(p);
end;

{ the rule set a rule belongs to }
function RuleSetOf(const ID: string): string;
begin
  if (Copy(ID, 1, 6) = 'BR-DE-') or (Copy(ID, 1, 7) = 'PEPPOL-') then begin
    result := 'XRechnung 3.0';
  end else begin
    result := 'EN 16931';
  end;
end;

{ all rules, none applied yet }
procedure InitRules(var r: TAbCheckReport);
var
  i: Integer;
begin
  SetLength(r.Rules, Length(RuleTable));

  for i := 0 to High(RuleTable) do begin
    r.Rules[i].ID := RuleTable[i].ID;
    r.Rules[i].Status := arsNotApplied;
    r.Rules[i].Origin := aboOfficial;
    if IsOwnRule(RuleTable[i].ID) then r.Rules[i].Origin := aboExtra;
  end;
end;

function IsDigit(c: Char): Boolean;
begin
  result := (c >= '0') and (c <= '9');
end;

{ IDs in reading order: numbers by value, so BR-DE-2 comes before BR-DE-10 }
function NaturalCompare(const a, b: string): Integer;
var
  i, j, si, sj: Integer;
  na, nb: Int64;
begin
  i := 1;
  j := 1;

  while (i <= Length(a)) and (j <= Length(b)) do begin
    if IsDigit(a[i]) and IsDigit(b[j]) then begin
      si := i;
      sj := j;
      while (i <= Length(a)) and IsDigit(a[i]) do begin
        Inc(i);
      end;

      while (j <= Length(b)) and IsDigit(b[j]) do begin
        Inc(j);
      end;

      na := StrToInt64Def(Copy(a, si, i - si), 0);
      nb := StrToInt64Def(Copy(b, sj, j - sj), 0);
      if na < nb then exit(-1);
      if na > nb then exit(1);
    end else begin
      if a[i] < b[j] then exit(-1);
      if a[i] > b[j] then exit(1);
      Inc(i);
      Inc(j);
    end;
  end;

  result := (Length(a) - i) - (Length(b) - j);
end;

{ keeps the rules of the applied rule sets and those applied as extra checks,
  in reading order }
procedure KeepRules(var r: TAbCheckReport);
var
  i, j, n: Integer;
  keep: Boolean;
  t: TAbRuleResult;
begin
  n := 0;

  for i := 0 to High(r.Rules) do begin
    keep := r.Rules[i].Status <> arsNotApplied;

    for j := 0 to High(r.RuleSets) do begin
      if r.RuleSets[j] = RuleSetOf(r.Rules[i].ID) then keep := true;
    end;

    if keep then begin
      r.Rules[n] := r.Rules[i];
      Inc(n);
    end;
  end;

  SetLength(r.Rules, n);

  for i := 1 to High(r.Rules) do begin
    t := r.Rules[i];
    j := i - 1;
    while (j >= 0) and (NaturalCompare(r.Rules[j].ID, t.ID) > 0) do begin
      r.Rules[j + 1] := r.Rules[j];
      Dec(j);
    end;

    r.Rules[j + 1] := t;
  end;
end;

procedure CheckInvoice(const Inv: TEInvoice; var r: TAbCheckReport);
var
  en: Boolean;
  i, n: Integer;
  path: string;
begin
  InitRules(r);
  en := (Inv.Specification = '') or (Pos('urn:cen.eu:en16931:2017', Inv.Specification) = 1);

  if Inv.Info.Syntax = eisynZUGFeRD1 then begin
    en := false;
    NotChecked(r, 'ZUGFeRD 1.0 predates EN 16931: content rules not applied');
  end else if Inv.Info.Profile in [eiprofMinimum, eiprofBasicWL] then begin
    en := false;
    NotChecked(r, 'Profile ' + ProfileText(Inv.Info.Profile) +
      ' is not an EN 16931 invoice: content rules not applied');
  end else if not en then begin
    NotChecked(r, 'Unknown specification identifier (BT-24): content rules not applied');
  end;

  if en then begin
    AddUnique(r.RuleSets, 'EN 16931');
    CheckMandatory(Inv, r);
    CheckTotals(Inv, r);
    CheckDecimals(Inv, r);

    if Inv.Info.Profile = eiprofExtended then begin
      NotChecked(r, 'Code lists (the EXTENDED profile has its own)');
    end else begin
      CheckCodes(Inv, r);
    end;

    CheckVat(Inv, r);
    CheckLineAmounts(Inv, r);
  end;

  if en and (Inv.Info.Profile = eiprofXRechnung) then begin
    if Pos('3.', Inv.Info.XRechnungVersion) = 1 then begin
      AddUnique(r.RuleSets, 'XRechnung 3.0');
      CheckXRechnung(Inv, r);

      if IsXRExtension(Inv) then begin
        NotChecked(r, 'Rules of the XRechnung extension (BR-DEX)');
      end;
    end else begin
      NotChecked(r, 'XRechnung ' + Inv.Info.XRechnungVersion +
        ': national rules (BR-DE) are only implemented for version 3.0');
    end;
  end;

  if Inv.Info.Profile = eiprofPeppol then begin
    NotChecked(r, 'Peppol BIS rules');
  end;

  if Inv.Info.Profile = eiprofExtended then begin
    NotChecked(r, 'Rules specific to the EXTENDED profile');
  end;

  for i := 0 to High(Inv.Lines) do begin
    if Inv.Lines[i].ParentID <> '' then begin
      NotChecked(r, 'Sub-lines (XRechnung extension)');
      break;
    end;
  end;

  if Inv.TaxCurrency <> '' then begin
    NotChecked(r, 'VAT total in accounting currency (BT-111) is not recalculated');
  end;

  n := Length(Inv.Unmapped);
  if n > 0 then begin
    path := Inv.Unmapped[0];
    i := Pos(' = ', path);
    if i > 0 then begin
      SetLength(path, i - 1);
    end;

    NotChecked(r, Format('%d element(s) outside EN 16931, e.g. %s', [n, path]));
  end;

  KeepRules(r);
end;

end.
