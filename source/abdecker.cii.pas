{ SPDX-License-Identifier: MIT
  Copyright (c) 2026 Ingo Jache }

unit abdecker.cii;

{ abdecker - CII (UN/CEFACT D16B) and ZUGFeRD 1.0 <-> invoice model
  (internal). Not part of the public API: use the unit abdecker. }

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
  abdecker, abdecker.read;

{ Reads a CII or ZUGFeRD 1.0 invoice (same structure, partly different names) }
procedure ParseCii(var r: TModelReader; Syn: TEInvoiceSyntax; var Inv: TEInvoice);

{ Writes the model as CII (D16B): every filled field, no calculation, no
  decisions. UTF-8 without BOM, LF, two spaces indentation, the namespaces
  rsm, ram, qdt, udt on the root. Without the abdecker mark (XmlMark). }
function CiiFromModel(const Inv: TEInvoice): TBytes;

implementation

uses
  abdecker.util;

{ CII uses UNTDID 2475 for the VAT point date code, EN 16931 uses UNTDID 2005 }
function MapDueDateCode(const c: string): string;
begin
  if c = '5' then result := '3'
  else if c = '29' then result := '35'
  else if c = '72' then result := '432'
  else result := c;
end;

{ ---- CII (D16B) and ZUGFeRD 1.0: same structure, partly different names ---- }

type
  TCiiNames = record
    Context, Document, Transaction, Agreement, Delivery, Settlement, Summation: string;
    LineAgreement, LineDelivery, LineSettlement, LineSummation: string;
    Rate, RefID: string;
  end;

function CiiNames(Syn: TEInvoiceSyntax): TCiiNames;
begin
  if Syn = eisynZUGFeRD1 then begin
    result.Context := 'SpecifiedExchangedDocumentContext';
    result.Document := 'HeaderExchangedDocument';
    result.Transaction := 'SpecifiedSupplyChainTradeTransaction';
    result.Agreement := 'ApplicableSupplyChainTradeAgreement';
    result.Delivery := 'ApplicableSupplyChainTradeDelivery';
    result.Settlement := 'ApplicableSupplyChainTradeSettlement';
    result.Summation := 'SpecifiedTradeSettlementMonetarySummation';
    result.LineAgreement := 'SpecifiedSupplyChainTradeAgreement';
    result.LineDelivery := 'SpecifiedSupplyChainTradeDelivery';
    result.LineSettlement := 'SpecifiedSupplyChainTradeSettlement';
    result.LineSummation := 'SpecifiedTradeSettlementMonetarySummation';
    result.Rate := 'ApplicablePercent';
    result.RefID := 'ID';
  end else begin
    result.Context := 'ExchangedDocumentContext';
    result.Document := 'ExchangedDocument';
    result.Transaction := 'SupplyChainTradeTransaction';
    result.Agreement := 'ApplicableHeaderTradeAgreement';
    result.Delivery := 'ApplicableHeaderTradeDelivery';
    result.Settlement := 'ApplicableHeaderTradeSettlement';
    result.Summation := 'SpecifiedTradeSettlementHeaderMonetarySummation';
    result.LineAgreement := 'SpecifiedLineTradeAgreement';
    result.LineDelivery := 'SpecifiedLineTradeDelivery';
    result.LineSettlement := 'SpecifiedLineTradeSettlement';
    result.LineSummation := 'SpecifiedTradeSettlementLineMonetarySummation';
    result.Rate := 'RateApplicablePercent';
    result.RefID := 'IssuerAssignedID';
  end;
end;

{ All Content children of an IncludedNote (ZUGFeRD 1.0 allows several) }
function CiiNoteText(var r: TModelReader; Note: Integer): string;
var
  x: Integer;
begin
  result := '';
  x := r.First(Note, 'Content');
  while x >= 0 do begin
    AppendText(result, r.TextOf(x));
    x := r.Next(x);
  end;
end;

procedure ReadCiiAddress(var r: TModelReader; e: Integer; var a: TEInvoiceAddress);
begin
  a.PostCode := r.Str(e, 'PostcodeCode');
  a.Line1 := r.Str(e, 'LineOne');
  a.Line2 := r.Str(e, 'LineTwo');
  a.Line3 := r.Str(e, 'LineThree');
  a.City := r.Str(e, 'CityName');
  a.Country := r.Str(e, 'CountryID');
  a.Subdivision := r.Str(e, 'CountrySubDivisionName');
end;

procedure ReadCiiParty(var r: TModelReader; e: Integer; var p: TEInvoiceParty);
var
  x, y: Integer;
  v, dept: string;
begin
  if e < 0 then exit;
  x := r.First(e, 'ID');
  while x >= 0 do begin
    AddID(p.IDs, r.IdentOf(x, 'schemeID'));
    x := r.Next(x);
  end;

  x := r.First(e, 'GlobalID');
  while x >= 0 do begin
    AddID(p.IDs, r.IdentOf(x, 'schemeID'));
    x := r.Next(x);
  end;

  p.Name := r.Str(e, 'Name');
  p.LegalInfo := r.Str(e, 'Description');
  x := r.El(e, 'SpecifiedLegalOrganization');
  p.LegalID := r.Ident(x, 'ID');
  p.TradingName := r.Str(x, 'TradingBusinessName');
  x := r.El(e, 'DefinedTradeContact');
  p.Contact.Name := r.Str(x, 'PersonName');
  dept := r.Str(x, 'DepartmentName');
  if p.Contact.Name = '' then p.Contact.Name := dept;
  p.Contact.Phone := r.Str(x, 'TelephoneUniversalCommunication/CompleteNumber');
  p.Contact.Email := r.Str(x, 'EmailURIUniversalCommunication/URIID');
  ReadCiiAddress(r, r.El(e, 'PostalTradeAddress'), p.Address);
  p.ElectronicAddress := r.Ident(e, 'URIUniversalCommunication/URIID');
  x := r.First(e, 'SpecifiedTaxRegistration');
  while x >= 0 do begin
    y := r.El(x, 'ID');
    v := r.TextOf(y);

    if r.Attr(y, 'schemeID') = 'FC' then begin
      p.TaxNumber := v;
    end else begin
      p.VATID := v;
    end;

    x := r.Next(x);
  end;
end;

procedure ReadCiiAllowanceCharge(var r: TModelReader; e: Integer; const n: TCiiNames;
  const Grp: string; out AC: TEInvoiceAllowanceCharge);
var
  t: Integer;
begin
  AC := Default(TEInvoiceAllowanceCharge);
  AC.IsCharge := SameText(r.Str(e, 'ChargeIndicator/Indicator'), 'true');
  AC.Percent := r.Num(e, 'CalculationPercent', Grp);
  AC.BaseAmount := r.Num(e, 'BasisAmount', Grp);
  AC.Amount := r.Num(e, 'ActualAmount', Grp);
  AC.ReasonCode := r.Str(e, 'ReasonCode');
  AC.Reason := r.Str(e, 'Reason');
  t := r.El(e, 'CategoryTradeTax');
  r.Skip(t, 'TypeCode');
  AC.TaxCategory := r.Str(t, 'CategoryCode');
  AC.TaxRate := r.Num(t, n.Rate, Grp);
end;

procedure ReadCiiLine(var r: TModelReader; e: Integer; const n: TCiiNames; out l: TEInvoiceLine);
var
  x, y, g, b: Integer;
  ac: TEInvoiceAllowanceCharge;
  ia: TEInvoiceItemAttribute;
  grossBase: TAbDecimal;
  grossUnit: string;
begin
  l := Default(TEInvoiceLine);
  x := r.El(e, 'AssociatedDocumentLineDocument');
  l.ID := r.Str(x, 'LineID');
  l.ParentID := r.Str(x, 'ParentLineID');
  y := r.First(x, 'IncludedNote');
  while y >= 0 do begin
    AppendText(l.Note, CiiNoteText(r, y));
    y := r.Next(y);
  end;

  x := r.El(e, 'SpecifiedTradeProduct');
  l.StandardItemID := r.Ident(x, 'GlobalID');
  l.SellerItemID := r.Str(x, 'SellerAssignedID');
  l.BuyerItemID := r.Str(x, 'BuyerAssignedID');
  l.ItemName := r.Str(x, 'Name');
  l.ItemDescription := r.Str(x, 'Description');
  y := r.First(x, 'ApplicableProductCharacteristic');
  while y >= 0 do begin
    ia.Name := r.Str(y, 'Description');
    ia.Value := r.Str(y, 'Value');
    SetLength(l.Attributes, Length(l.Attributes) + 1);
    l.Attributes[High(l.Attributes)] := ia;
    y := r.Next(y);
  end;

  y := r.First(x, 'DesignatedProductClassification');
  while y >= 0 do begin
    AddID(l.Classifications, r.IdentOf(r.El(y, 'ClassCode'), 'listID'));
    y := r.Next(y);
  end;

  l.OriginCountry := r.Str(x, 'OriginTradeCountry/ID');

  x := r.El(e, n.LineAgreement);
  l.OrderLineRef := r.Str(x, 'BuyerOrderReferencedDocument/LineID');
  g := r.El(x, 'GrossPriceProductTradePrice');
  l.GrossPrice := r.Num(g, 'ChargeAmount', 'BT-148');
  b := r.El(g, 'BasisQuantity');
  grossBase := r.NumOf(b, 'BT-149');
  grossUnit := r.Attr(b, 'unitCode');
  y := r.First(g, 'AppliedTradeAllowanceCharge');
  while y >= 0 do begin
    r.Skip(y, 'ChargeIndicator/Indicator');
    l.PriceDiscount := r.Num(y, 'ActualAmount', 'BT-147');
    y := r.Next(y);
  end;

  g := r.El(x, 'NetPriceProductTradePrice');
  l.NetPrice := r.Num(g, 'ChargeAmount', 'BT-146');
  b := r.El(g, 'BasisQuantity');
  l.BaseQuantity := r.NumOf(b, 'BT-149');
  l.BaseQuantityUnit := r.Attr(b, 'unitCode');

  if not l.BaseQuantity.Present then begin
    l.BaseQuantity := grossBase;
    l.BaseQuantityUnit := grossUnit;
  end;

  x := r.El(e, n.LineDelivery);
  b := r.El(x, 'BilledQuantity');
  l.Quantity := r.NumOf(b, 'BT-129');
  l.UnitCode := r.Attr(b, 'unitCode');

  x := r.El(e, n.LineSettlement);
  y := r.El(x, 'ApplicableTradeTax');
  r.Skip(y, 'TypeCode');
  l.TaxCategory := r.Str(y, 'CategoryCode');
  l.TaxRate := r.Num(y, n.Rate, 'BT-152');
  y := r.El(x, 'BillingSpecifiedPeriod');
  l.PeriodStart := r.DateStr(y, 'StartDateTime/DateTimeString');
  l.PeriodEnd := r.DateStr(y, 'EndDateTime/DateTimeString');
  y := r.First(x, 'SpecifiedTradeAllowanceCharge');
  while y >= 0 do begin
    ReadCiiAllowanceCharge(r, y, n, 'BG-27/28', ac);
    AddAC(l.AllowancesCharges, ac);
    y := r.Next(y);
  end;

  l.NetAmount := r.Num(x, n.LineSummation + '/LineTotalAmount', 'BT-131');
  y := r.El(x, 'AdditionalReferencedDocument');
  l.ObjectID.Value := r.Str(y, 'IssuerAssignedID');
  l.ObjectID.Scheme := r.Str(y, 'ReferenceTypeCode');
  r.Skip(y, 'TypeCode');
  l.AccountingRef := r.Str(x, 'ReceivableSpecifiedTradeAccountingAccount/ID');
  if l.AccountingRef = '' then l.AccountingRef := r.Str(x, 'SpecifiedTradeAccountingAccount/ID');
end;

procedure ParseCii(var r: TModelReader; Syn: TEInvoiceSyntax; var Inv: TEInvoice);
var
  n: TCiiNames;
  x, y, b, t, s, m: Integer;
  code, v: string;
  note: TEInvoiceNote;
  docu: TEInvoiceDocument;
  acc: TEInvoiceAccount;
  tax: TEInvoiceTax;
  ac: TEInvoiceAllowanceCharge;
  ref: TEInvoiceReference;
  line: TEInvoiceLine;
begin
  n := CiiNames(Syn);
  x := r.El(0, n.Context);
  Inv.BusinessProcess := r.Str(x, 'BusinessProcessSpecifiedDocumentContextParameter/ID');
  Inv.Specification := r.Str(x, 'GuidelineSpecifiedDocumentContextParameter/ID');

  x := r.El(0, n.Document);
  Inv.Number := r.Str(x, 'ID');
  Inv.TypeCode := r.Str(x, 'TypeCode');
  Inv.IssueDate := r.DateStr(x, 'IssueDateTime/DateTimeString');
  y := r.First(x, 'IncludedNote');
  while y >= 0 do begin
    note.SubjectCode := r.Str(y, 'SubjectCode');
    note.Text := CiiNoteText(r, y);
    SetLength(Inv.Notes, Length(Inv.Notes) + 1);
    Inv.Notes[High(Inv.Notes)] := note;
    y := r.Next(y);
  end;

  t := r.El(0, n.Transaction);

  // agreement: parties and references
  x := r.El(t, n.Agreement);
  Inv.BuyerReference := r.Str(x, 'BuyerReference');
  ReadCiiParty(r, r.El(x, 'SellerTradeParty'), Inv.Seller);
  ReadCiiParty(r, r.El(x, 'BuyerTradeParty'), Inv.Buyer);
  ReadCiiParty(r, r.El(x, 'SellerTaxRepresentativeTradeParty'), Inv.TaxRepresentative);
  Inv.SalesOrderRef := r.Str(x, 'SellerOrderReferencedDocument/' + n.RefID);
  Inv.OrderRef := r.Str(x, 'BuyerOrderReferencedDocument/' + n.RefID);
  Inv.ContractRef := r.Str(x, 'ContractReferencedDocument/' + n.RefID);
  y := r.First(x, 'AdditionalReferencedDocument');
  while y >= 0 do begin
    code := r.Str(y, 'TypeCode');
    if code = '130' then begin
      Inv.InvoicedObject.Value := r.Str(y, n.RefID);
      Inv.InvoicedObject.Scheme := r.Str(y, 'ReferenceTypeCode');
    end else if code = '50' then begin
      Inv.TenderRef := r.Str(y, n.RefID);
    end else begin
      docu := Default(TEInvoiceDocument);
      docu.ID := r.Str(y, n.RefID);
      docu.Description := r.Str(y, 'Name');
      docu.URI := r.Str(y, 'URIID');
      b := r.El(y, 'AttachmentBinaryObject');
      if b >= 0 then begin
        docu.Content := DecodeBase64(r.TextOf(b));
        docu.MimeType := r.Attr(b, 'mimeCode');
        docu.FileName := r.Attr(b, 'filename');
      end;

      SetLength(Inv.Documents, Length(Inv.Documents) + 1);
      Inv.Documents[High(Inv.Documents)] := docu;
    end;

    y := r.Next(y);
  end;

  Inv.ProjectRef := r.Str(x, 'SpecifiedProcuringProject/ID');
  r.Skip(x, 'SpecifiedProcuringProject/Name');

  // delivery
  x := r.El(t, n.Delivery);
  y := r.El(x, 'ShipToTradeParty');
  Inv.Delivery.PartyName := r.Str(y, 'Name');
  Inv.Delivery.LocationID := r.Ident(y, 'ID');
  if Inv.Delivery.LocationID.Value = '' then Inv.Delivery.LocationID := r.Ident(y, 'GlobalID');
  ReadCiiAddress(r, r.El(y, 'PostalTradeAddress'), Inv.Delivery.Address);
  Inv.Delivery.Date := r.DateStr(x, 'ActualDeliverySupplyChainEvent/OccurrenceDateTime/DateTimeString');
  Inv.DespatchAdviceRef := r.Str(x, 'DespatchAdviceReferencedDocument/' + n.RefID);
  if Inv.DespatchAdviceRef = '' then begin
    Inv.DespatchAdviceRef := r.Str(x, 'DeliveryNoteReferencedDocument/' + n.RefID);
  end;

  Inv.ReceivingAdviceRef := r.Str(x, 'ReceivingAdviceReferencedDocument/' + n.RefID);

  // settlement
  s := r.El(t, n.Settlement);
  Inv.Payment.CreditorID := r.Str(s, 'CreditorReferenceID');
  Inv.Payment.RemittanceInfo := r.Str(s, 'PaymentReference');
  Inv.TaxCurrency := r.Str(s, 'TaxCurrencyCode');
  Inv.Currency := r.Str(s, 'InvoiceCurrencyCode');
  ReadCiiParty(r, r.El(s, 'PayeeTradeParty'), Inv.Payee);

  y := r.First(s, 'SpecifiedTradeSettlementPaymentMeans');
  while y >= 0 do begin
    code := r.Str(y, 'TypeCode');
    SetLength(Inv.Payment.MeansCodes, Length(Inv.Payment.MeansCodes) + 1);
    Inv.Payment.MeansCodes[High(Inv.Payment.MeansCodes)] := code;
    v := r.Str(y, 'Information');

    if Inv.Payment.MeansCode = '' then begin
      Inv.Payment.MeansCode := code;
      Inv.Payment.MeansText := v;
    end;

    x := r.El(y, 'ApplicableTradeSettlementFinancialCard');
    if x >= 0 then begin
      Inv.Payment.CardNumber := r.Str(x, 'ID');
      Inv.Payment.CardHolder := r.Str(x, 'CardholderName');
    end;

    v := r.Str(y, 'PayerPartyDebtorFinancialAccount/IBANID');
    if v <> '' then Inv.Payment.DebitedAccount := v;
    x := r.El(y, 'PayeePartyCreditorFinancialAccount');
    if x >= 0 then begin
      acc.IBAN := r.Str(x, 'IBANID');
      v := r.Str(x, 'ProprietaryID');
      if acc.IBAN = '' then acc.IBAN := v;
      acc.Name := r.Str(x, 'AccountName');
      acc.BIC := r.Str(y, 'PayeeSpecifiedCreditorFinancialInstitution/BICID');
      SetLength(Inv.Payment.Accounts, Length(Inv.Payment.Accounts) + 1);
      Inv.Payment.Accounts[High(Inv.Payment.Accounts)] := acc;
    end;

    y := r.Next(y);
  end;

  y := r.First(s, 'ApplicableTradeTax');
  while y >= 0 do begin
    tax := Default(TEInvoiceTax);
    tax.TaxAmount := r.Num(y, 'CalculatedAmount', 'BT-117');
    r.Skip(y, 'TypeCode');
    tax.ExemptionReason := r.Str(y, 'ExemptionReason');
    tax.TaxableAmount := r.Num(y, 'BasisAmount', 'BT-116');
    tax.Category := r.Str(y, 'CategoryCode');
    tax.ExemptionReasonCode := r.Str(y, 'ExemptionReasonCode');
    v := MapDueDateCode(r.Str(y, 'DueDateTypeCode'));
    if v <> '' then Inv.TaxPointDateCode := v;
    v := r.DateStr(y, 'TaxPointDate/DateString');
    if v <> '' then Inv.TaxPointDate := v;
    tax.Rate := r.Num(y, n.Rate, 'BT-119');
    SetLength(Inv.Taxes, Length(Inv.Taxes) + 1);
    Inv.Taxes[High(Inv.Taxes)] := tax;
    y := r.Next(y);
  end;

  x := r.El(s, 'BillingSpecifiedPeriod');
  Inv.PeriodStart := r.DateStr(x, 'StartDateTime/DateTimeString');
  Inv.PeriodEnd := r.DateStr(x, 'EndDateTime/DateTimeString');

  y := r.First(s, 'SpecifiedTradeAllowanceCharge');
  while y >= 0 do begin
    ReadCiiAllowanceCharge(r, y, n, 'BG-20/21', ac);
    AddAC(Inv.AllowancesCharges, ac);
    y := r.Next(y);
  end;
  // ZUGFeRD 1.0 / EXTENDED: logistics charges are document level charges
  y := r.First(s, 'SpecifiedLogisticsServiceCharge');
  while y >= 0 do begin
    ac := Default(TEInvoiceAllowanceCharge);
    ac.IsCharge := true;
    ac.Reason := r.Str(y, 'Description');
    ac.Amount := r.Num(y, 'AppliedAmount', 'BT-99');
    x := r.El(y, 'AppliedTradeTax');
    r.Skip(x, 'TypeCode');
    ac.TaxCategory := r.Str(x, 'CategoryCode');
    ac.TaxRate := r.Num(x, n.Rate, 'BT-103');
    AddAC(Inv.AllowancesCharges, ac);
    y := r.Next(y);
  end;

  y := r.First(s, 'SpecifiedTradePaymentTerms');
  while y >= 0 do begin
    AppendText(Inv.PaymentTerms, r.RawStr(y, 'Description'));
    v := r.DateStr(y, 'DueDateDateTime/DateTimeString');
    if (v <> '') and (Inv.DueDate = '') then Inv.DueDate := v;
    v := r.Str(y, 'DirectDebitMandateID');
    if v <> '' then Inv.Payment.MandateID := v;
    y := r.Next(y);
  end;

  m := r.El(s, n.Summation);
  Inv.Totals.LineTotal := r.Num(m, 'LineTotalAmount', 'BT-106');
  Inv.Totals.ChargeTotal := r.Num(m, 'ChargeTotalAmount', 'BT-108');
  Inv.Totals.AllowanceTotal := r.Num(m, 'AllowanceTotalAmount', 'BT-107');
  Inv.Totals.TaxExclusive := r.Num(m, 'TaxBasisTotalAmount', 'BT-109');
  y := r.First(m, 'TaxTotalAmount');
  while y >= 0 do begin
    v := r.Attr(y, 'currencyID');
    if (v <> '') and (v <> Inv.Currency) and (v = Inv.TaxCurrency) then begin
      Inv.Totals.TaxTotalTaxCurrency := r.NumOf(y, 'BT-111');
    end else begin
      Inv.Totals.TaxTotal := r.NumOf(y, 'BT-110');
    end;

    y := r.Next(y);
  end;

  Inv.Totals.Rounding := r.Num(m, 'RoundingAmount', 'BT-114');
  Inv.Totals.TaxInclusive := r.Num(m, 'GrandTotalAmount', 'BT-112');
  Inv.Totals.Prepaid := r.Num(m, 'TotalPrepaidAmount', 'BT-113');
  Inv.Totals.DuePayable := r.Num(m, 'DuePayableAmount', 'BT-115');

  y := r.First(s, 'InvoiceReferencedDocument');
  while y >= 0 do begin
    ref.Number := r.Str(y, 'IssuerAssignedID');
    ref.Date := r.DateStr(y, 'FormattedIssueDateTime/DateTimeString');
    SetLength(Inv.PrecedingInvoices, Length(Inv.PrecedingInvoices) + 1);
    Inv.PrecedingInvoices[High(Inv.PrecedingInvoices)] := ref;
    y := r.Next(y);
  end;

  Inv.AccountingRef := r.Str(s, 'ReceivableSpecifiedTradeAccountingAccount/ID');

  y := r.First(t, 'IncludedSupplyChainTradeLineItem');
  while y >= 0 do begin
    ReadCiiLine(r, y, n, line);
    SetLength(Inv.Lines, Length(Inv.Lines) + 1);
    Inv.Lines[High(Inv.Lines)] := line;
    y := r.Next(y);
  end;
end;

{ ===========================================================================
  Writing CII

  The writer puts out the model as it is. Groups are opened lazily: a group
  appears only once something is written into it, unless it is closed with
  Force (elements whose mere presence the reader counts, e.g. a line or a
  tax entry). Element order as in the D16B schema.
  =========================================================================== }

const
  NS_RSM = 'urn:un:unece:uncefact:data:standard:CrossIndustryInvoice:100';
  NS_RAM = 'urn:un:unece:uncefact:data:standard:ReusableAggregateBusinessInformationEntity:100';
  NS_QDT = 'urn:un:unece:uncefact:data:standard:QualifiedDataType:100';
  NS_UDT = 'urn:un:unece:uncefact:data:standard:UnqualifiedDataType:100';

type
  TCiiWriter = record
    Lines: array of string;
    Count: Integer;
    Tags, TagAttrs: array of string;
    Done: array of Boolean;
    procedure Line(const s: string);
    procedure FlushTo(n: Integer);
    procedure Open(const Tag: string; const Attrs: string = '');
    procedure Close(Force: Boolean = false);
    procedure Elem(const Tag, Value, Attrs: string);
    procedure Leaf(const Tag, Value: string; const Attrs: string = '');
    procedure RawLeaf(const Tag, Value: string);
    procedure Num(const Tag: string; const d: TAbDecimal; const Attrs: string = '');
    procedure Qty(const Tag: string; const d: TAbDecimal; const UnitCode: string);
    procedure Ident(const Tag: string; const ID: TEInvoiceID; const SchemeAttr: string = 'schemeID');
    procedure Date(const Tag, Value: string; const Prefix: string = 'udt');
    function Text: string;
  end;

function XmlEsc(const s: string; InAttr: Boolean): string;
var
  i: Integer;
  c: Char;
begin
  result := '';

  for i := 1 to Length(s) do begin
    c := s[i];

    case c of
      '&': result := result + '&amp;';
      '<': result := result + '&lt;';
      '>': result := result + '&gt;';
      #13: result := result + '&#13;';
    else
      if (c = '"') and InAttr then begin
        result := result + '&quot;';
      end else begin
        result := result + c;
      end;
    end;
  end;
end;

function Attr(const Name, Value: string): string;
begin
  if Value = '' then exit('');
  result := ' ' + Name + '="' + XmlEsc(Value, true) + '"';
end;

{ YYYY-MM-DD -> YYYYMMDD; anything else as it is (the reader keeps it as well) }
function Date102(const s: string): string;
var
  i: Integer;
begin
  result := s;
  if (Length(s) <> 10) or (s[5] <> '-') or (s[8] <> '-') then exit;

  for i := 1 to 10 do begin
    if (i <> 5) and (i <> 8) and ((s[i] < '0') or (s[i] > '9')) then exit;
  end;

  result := Copy(s, 1, 4) + Copy(s, 6, 2) + Copy(s, 9, 2);
end;

{ EN 16931 (UNTDID 2005) -> CII (UNTDID 2475), the reverse of MapDueDateCode }
function CiiDueDateCode(const c: string): string;
begin
  if c = '3' then result := '5'
  else if c = '35' then result := '29'
  else if c = '432' then result := '72'
  else result := c;
end;

procedure TCiiWriter.Line(const s: string);
begin
  if Count >= Length(Lines) then begin
    SetLength(Lines, Count * 2 + 64);
  end;

  Lines[Count] := s;
  Inc(Count);
end;

{ writes the start tags of the first N open groups that are still pending }
procedure TCiiWriter.FlushTo(n: Integer);
var
  i: Integer;
begin
  for i := 0 to n - 1 do begin
    if not Done[i] then begin
      Line(StringOfChar(' ', 2 * i) + '<' + Tags[i] + TagAttrs[i] + '>');
      Done[i] := true;
    end;
  end;
end;

procedure TCiiWriter.Open(const Tag, Attrs: string);
var
  n: Integer;
begin
  n := Length(Tags);
  SetLength(Tags, n + 1);
  SetLength(TagAttrs, n + 1);
  SetLength(Done, n + 1);
  Tags[n] := Tag;
  TagAttrs[n] := Attrs;
  Done[n] := false;
end;

procedure TCiiWriter.Close(Force: Boolean);
var
  n: Integer;
begin
  n := High(Tags);

  if Done[n] then begin
    Line(StringOfChar(' ', 2 * n) + '</' + Tags[n] + '>');
  end else if Force then begin
    FlushTo(n);
    Line(StringOfChar(' ', 2 * n) + '<' + Tags[n] + TagAttrs[n] + '/>');
  end;

  SetLength(Tags, n);
  SetLength(TagAttrs, n);
  SetLength(Done, n);
end;

{ an element with text, written even if empty }
procedure TCiiWriter.Elem(const Tag, Value, Attrs: string);
var
  n: Integer;
begin
  n := Length(Tags);
  FlushTo(n);

  if Value = '' then begin
    Line(StringOfChar(' ', 2 * n) + '<' + Tag + Attrs + '/>');
  end else begin
    Line(StringOfChar(' ', 2 * n) + '<' + Tag + Attrs + '>' + XmlEsc(Value, false) + '</' + Tag + '>');
  end;
end;

{ values are trimmed like the reader trims them; empty values are left out }
procedure TCiiWriter.Leaf(const Tag, Value, Attrs: string);
var
  v: string;
begin
  v := Trim(Value);
  if v <> '' then Elem(Tag, v, Attrs);
end;

{ untrimmed (payment terms: line breaks matter for XRechnung Skonto) }
procedure TCiiWriter.RawLeaf(const Tag, Value: string);
begin
  if Trim(Value) <> '' then Elem(Tag, Value, '');
end;

procedure TCiiWriter.Num(const Tag: string; const d: TAbDecimal; const Attrs: string);
begin
  if d.Present then Elem(Tag, d.ToString, Attrs);
end;

{ a quantity: written if the number or the unit is given }
procedure TCiiWriter.Qty(const Tag: string; const d: TAbDecimal; const UnitCode: string);
begin
  if d.Present or (Trim(UnitCode) <> '') then Elem(Tag, d.ToString, Attr('unitCode', Trim(UnitCode)));
end;

{ an identifier: written if the value or the scheme is given }
procedure TCiiWriter.Ident(const Tag: string; const ID: TEInvoiceID; const SchemeAttr: string);
begin
  if (Trim(ID.Value) <> '') or (Trim(ID.Scheme) <> '') then begin
    Elem(Tag, Trim(ID.Value), Attr(SchemeAttr, Trim(ID.Scheme)));
  end;
end;

procedure TCiiWriter.Date(const Tag, Value, Prefix: string);
begin
  if Trim(Value) = '' then exit;
  Open(Tag);
  Elem(Prefix + ':DateTimeString', Date102(Trim(Value)), ' format="102"');
  Close;
end;

function TCiiWriter.Text: string;
var
  i, n, p: Integer;
begin
  n := 0;

  for i := 0 to Count - 1 do begin
    Inc(n, Length(Lines[i]) + 1);
  end;

  SetLength(result, n);
  p := 1;

  for i := 0 to Count - 1 do begin
    if Lines[i] <> '' then begin
      Move(Lines[i][1], result[p], Length(Lines[i]) * SizeOf(Char));
    end;

    Inc(p, Length(Lines[i]));
    result[p] := #10;
    Inc(p);
  end;
end;

procedure WriteCiiAddress(var w: TCiiWriter; const Tag: string; const a: TEInvoiceAddress);
begin
  w.Open(Tag);
  w.Leaf('ram:PostcodeCode', a.PostCode);
  w.Leaf('ram:LineOne', a.Line1);
  w.Leaf('ram:LineTwo', a.Line2);
  w.Leaf('ram:LineThree', a.Line3);
  w.Leaf('ram:CityName', a.City);
  w.Leaf('ram:CountryID', a.Country);
  w.Leaf('ram:CountrySubDivisionName', a.Subdivision);
  w.Close;
end;

{ Party identifiers: the reader takes all ram:ID, then all ram:GlobalID. Up to
  the last one without a scheme they go into ram:ID, the rest (all with a
  scheme) into ram:GlobalID; reading back gives the same order. }
procedure WriteCiiPartyIDs(var w: TCiiWriter; const IDs: TEInvoiceIDs);
var
  i, k: Integer;
begin
  k := 0;

  for i := 0 to High(IDs) do begin
    if Trim(IDs[i].Scheme) = '' then k := i + 1;
  end;

  for i := 0 to High(IDs) do begin
    if i < k then begin
      w.Ident('ram:ID', IDs[i]);
    end else begin
      w.Ident('ram:GlobalID', IDs[i]);
    end;
  end;
end;

procedure WriteCiiParty(var w: TCiiWriter; const Tag: string; const p: TEInvoiceParty);
begin
  w.Open(Tag);
  WriteCiiPartyIDs(w, p.IDs);
  w.Leaf('ram:Name', p.Name);
  w.Leaf('ram:Description', p.LegalInfo);
  w.Open('ram:SpecifiedLegalOrganization');
  w.Ident('ram:ID', p.LegalID);
  w.Leaf('ram:TradingBusinessName', p.TradingName);
  w.Close;
  w.Open('ram:DefinedTradeContact');
  w.Leaf('ram:PersonName', p.Contact.Name);
  w.Open('ram:TelephoneUniversalCommunication');
  w.Leaf('ram:CompleteNumber', p.Contact.Phone);
  w.Close;
  w.Open('ram:EmailURIUniversalCommunication');
  w.Leaf('ram:URIID', p.Contact.Email);
  w.Close;
  w.Close;
  WriteCiiAddress(w, 'ram:PostalTradeAddress', p.Address);
  w.Open('ram:URIUniversalCommunication');
  w.Ident('ram:URIID', p.ElectronicAddress);
  w.Close;
  w.Open('ram:SpecifiedTaxRegistration');
  w.Leaf('ram:ID', p.VATID, ' schemeID="VA"');
  w.Close;
  w.Open('ram:SpecifiedTaxRegistration');
  w.Leaf('ram:ID', p.TaxNumber, ' schemeID="FC"');
  w.Close;
  w.Close;
end;

procedure WriteCiiAllowanceCharge(var w: TCiiWriter; const AC: TEInvoiceAllowanceCharge);
begin
  w.Open('ram:SpecifiedTradeAllowanceCharge');
  w.Open('ram:ChargeIndicator');

  if AC.IsCharge then begin
    w.Elem('udt:Indicator', 'true', '');
  end else begin
    w.Elem('udt:Indicator', 'false', '');
  end;

  w.Close;
  w.Num('ram:CalculationPercent', AC.Percent);
  w.Num('ram:BasisAmount', AC.BaseAmount);
  w.Num('ram:ActualAmount', AC.Amount);
  w.Leaf('ram:ReasonCode', AC.ReasonCode);
  w.Leaf('ram:Reason', AC.Reason);
  w.Open('ram:CategoryTradeTax');
  if (Trim(AC.TaxCategory) <> '') or AC.TaxRate.Present then w.Elem('ram:TypeCode', 'VAT', '');
  w.Leaf('ram:CategoryCode', AC.TaxCategory);
  w.Num('ram:RateApplicablePercent', AC.TaxRate);
  w.Close;
  w.Close(true);
end;

procedure WriteCiiPeriod(var w: TCiiWriter; const Start, Stop: string);
begin
  w.Open('ram:BillingSpecifiedPeriod');
  w.Date('ram:StartDateTime', Start);
  w.Date('ram:EndDateTime', Stop);
  w.Close;
end;

procedure WriteCiiLine(var w: TCiiWriter; const l: TEInvoiceLine);
var
  i: Integer;
begin
  w.Open('ram:IncludedSupplyChainTradeLineItem');

  w.Open('ram:AssociatedDocumentLineDocument');
  w.Leaf('ram:LineID', l.ID);
  w.Leaf('ram:ParentLineID', l.ParentID);
  w.Open('ram:IncludedNote');
  w.Leaf('ram:Content', l.Note);
  w.Close;
  w.Close;

  w.Open('ram:SpecifiedTradeProduct');
  w.Ident('ram:GlobalID', l.StandardItemID);
  w.Leaf('ram:SellerAssignedID', l.SellerItemID);
  w.Leaf('ram:BuyerAssignedID', l.BuyerItemID);
  w.Leaf('ram:Name', l.ItemName);
  w.Leaf('ram:Description', l.ItemDescription);

  for i := 0 to High(l.Attributes) do begin
    w.Open('ram:ApplicableProductCharacteristic');
    w.Leaf('ram:Description', l.Attributes[i].Name);
    w.Leaf('ram:Value', l.Attributes[i].Value);
    w.Close(true);
  end;

  for i := 0 to High(l.Classifications) do begin
    w.Open('ram:DesignatedProductClassification');
    w.Ident('ram:ClassCode', l.Classifications[i], 'listID');
    w.Close;
  end;

  w.Open('ram:OriginTradeCountry');
  w.Leaf('ram:ID', l.OriginCountry);
  w.Close;
  w.Close;

  w.Open('ram:SpecifiedLineTradeAgreement');
  w.Open('ram:BuyerOrderReferencedDocument');
  w.Leaf('ram:LineID', l.OrderLineRef);
  w.Close;
  w.Open('ram:GrossPriceProductTradePrice');
  w.Num('ram:ChargeAmount', l.GrossPrice);

  if l.PriceDiscount.Present then begin
    w.Open('ram:AppliedTradeAllowanceCharge');
    w.Open('ram:ChargeIndicator');
    w.Elem('udt:Indicator', 'false', '');
    w.Close;
    w.Num('ram:ActualAmount', l.PriceDiscount);
    w.Close;
  end;

  w.Close;
  w.Open('ram:NetPriceProductTradePrice');
  w.Num('ram:ChargeAmount', l.NetPrice);
  w.Qty('ram:BasisQuantity', l.BaseQuantity, l.BaseQuantityUnit);
  w.Close;
  w.Close;

  w.Open('ram:SpecifiedLineTradeDelivery');
  w.Qty('ram:BilledQuantity', l.Quantity, l.UnitCode);
  w.Close;

  w.Open('ram:SpecifiedLineTradeSettlement');
  w.Open('ram:ApplicableTradeTax');
  if (Trim(l.TaxCategory) <> '') or l.TaxRate.Present then w.Elem('ram:TypeCode', 'VAT', '');
  w.Leaf('ram:CategoryCode', l.TaxCategory);
  w.Num('ram:RateApplicablePercent', l.TaxRate);
  w.Close;
  WriteCiiPeriod(w, l.PeriodStart, l.PeriodEnd);

  for i := 0 to High(l.AllowancesCharges) do begin
    WriteCiiAllowanceCharge(w, l.AllowancesCharges[i]);
  end;

  w.Open('ram:SpecifiedTradeSettlementLineMonetarySummation');
  w.Num('ram:LineTotalAmount', l.NetAmount);
  w.Close;

  if (Trim(l.ObjectID.Value) <> '') or (Trim(l.ObjectID.Scheme) <> '') then begin
    w.Open('ram:AdditionalReferencedDocument');
    w.Leaf('ram:IssuerAssignedID', l.ObjectID.Value);
    w.Elem('ram:TypeCode', '130', '');
    w.Leaf('ram:ReferenceTypeCode', l.ObjectID.Scheme);
    w.Close;
  end;

  w.Open('ram:ReceivableSpecifiedTradeAccountingAccount');
  w.Leaf('ram:ID', l.AccountingRef);
  w.Close;
  w.Close;

  w.Close(true);
end;

procedure WriteCiiAgreement(var w: TCiiWriter; const Inv: TEInvoice);
var
  i: Integer;
  d: TEInvoiceDocument;
begin
  w.Open('ram:ApplicableHeaderTradeAgreement');
  w.Leaf('ram:BuyerReference', Inv.BuyerReference);
  WriteCiiParty(w, 'ram:SellerTradeParty', Inv.Seller);
  WriteCiiParty(w, 'ram:BuyerTradeParty', Inv.Buyer);
  WriteCiiParty(w, 'ram:SellerTaxRepresentativeTradeParty', Inv.TaxRepresentative);
  w.Open('ram:SellerOrderReferencedDocument');
  w.Leaf('ram:IssuerAssignedID', Inv.SalesOrderRef);
  w.Close;
  w.Open('ram:BuyerOrderReferencedDocument');
  w.Leaf('ram:IssuerAssignedID', Inv.OrderRef);
  w.Close;
  w.Open('ram:ContractReferencedDocument');
  w.Leaf('ram:IssuerAssignedID', Inv.ContractRef);
  w.Close;

  for i := 0 to High(Inv.Documents) do begin
    d := Inv.Documents[i];
    w.Open('ram:AdditionalReferencedDocument');
    w.Leaf('ram:IssuerAssignedID', d.ID);
    w.Leaf('ram:URIID', d.URI);
    w.Elem('ram:TypeCode', '916', '');
    w.Leaf('ram:Name', d.Description);

    if (Length(d.Content) > 0) or (Trim(d.MimeType) <> '') or (Trim(d.FileName) <> '') then begin
      w.Elem('ram:AttachmentBinaryObject', EncodeBase64(d.Content),
        Attr('mimeCode', Trim(d.MimeType)) + Attr('filename', Trim(d.FileName)));
    end;

    w.Close;
  end;

  if Trim(Inv.TenderRef) <> '' then begin
    w.Open('ram:AdditionalReferencedDocument');
    w.Leaf('ram:IssuerAssignedID', Inv.TenderRef);
    w.Elem('ram:TypeCode', '50', '');
    w.Close;
  end;

  if (Trim(Inv.InvoicedObject.Value) <> '') or (Trim(Inv.InvoicedObject.Scheme) <> '') then begin
    w.Open('ram:AdditionalReferencedDocument');
    w.Leaf('ram:IssuerAssignedID', Inv.InvoicedObject.Value);
    w.Elem('ram:TypeCode', '130', '');
    w.Leaf('ram:ReferenceTypeCode', Inv.InvoicedObject.Scheme);
    w.Close;
  end;

  // the schema demands a name; the CII binding of EN 16931 fixes its text
  if Trim(Inv.ProjectRef) <> '' then begin
    w.Open('ram:SpecifiedProcuringProject');
    w.Leaf('ram:ID', Inv.ProjectRef);
    w.Elem('ram:Name', 'Project reference', '');
    w.Close;
  end;

  w.Close(true);
end;

procedure WriteCiiDelivery(var w: TCiiWriter; const Inv: TEInvoice);
begin
  w.Open('ram:ApplicableHeaderTradeDelivery');
  w.Open('ram:ShipToTradeParty');

  if Trim(Inv.Delivery.LocationID.Scheme) = '' then begin
    w.Ident('ram:ID', Inv.Delivery.LocationID);
  end else begin
    w.Ident('ram:GlobalID', Inv.Delivery.LocationID);
  end;

  w.Leaf('ram:Name', Inv.Delivery.PartyName);
  WriteCiiAddress(w, 'ram:PostalTradeAddress', Inv.Delivery.Address);
  w.Close;
  w.Open('ram:ActualDeliverySupplyChainEvent');
  w.Date('ram:OccurrenceDateTime', Inv.Delivery.Date);
  w.Close;
  w.Open('ram:DespatchAdviceReferencedDocument');
  w.Leaf('ram:IssuerAssignedID', Inv.DespatchAdviceRef);
  w.Close;
  w.Open('ram:ReceivingAdviceReferencedDocument');
  w.Leaf('ram:IssuerAssignedID', Inv.ReceivingAdviceRef);
  w.Close;
  w.Close(true);
end;

{ One payment means element per code (MeansCodes, else MeansCode), and more
  if there are more accounts; card, debited account and text go into the
  first one. }
procedure WriteCiiPaymentMeans(var w: TCiiWriter; const Pay: TEInvoicePayment);
var
  codes: TAbStrings;
  i, n: Integer;
  any: Boolean;
begin
  codes := Pay.MeansCodes;
  any := (Trim(Pay.MeansCode) <> '') or (Trim(Pay.MeansText) <> '') or (Length(Pay.Accounts) > 0) or
    (Trim(Pay.CardNumber) <> '') or (Trim(Pay.CardHolder) <> '') or (Trim(Pay.DebitedAccount) <> '');

  if (Length(codes) = 0) and any then begin
    SetLength(codes, 1);
    codes[0] := Pay.MeansCode;
  end;

  n := Length(codes);
  if Length(Pay.Accounts) > n then n := Length(Pay.Accounts);

  for i := 0 to n - 1 do begin
    w.Open('ram:SpecifiedTradeSettlementPaymentMeans');

    if i < Length(codes) then begin
      w.Leaf('ram:TypeCode', codes[i]);
    end else begin
      w.Leaf('ram:TypeCode', codes[High(codes)]);
    end;

    if i = 0 then begin
      w.Leaf('ram:Information', Pay.MeansText);
      w.Open('ram:ApplicableTradeSettlementFinancialCard');
      w.Leaf('ram:ID', Pay.CardNumber);
      w.Leaf('ram:CardholderName', Pay.CardHolder);
      w.Close;
      w.Open('ram:PayerPartyDebtorFinancialAccount');
      w.Leaf('ram:IBANID', Pay.DebitedAccount);
      w.Close;
    end;

    if i < Length(Pay.Accounts) then begin
      w.Open('ram:PayeePartyCreditorFinancialAccount');
      w.Leaf('ram:IBANID', Pay.Accounts[i].IBAN);
      w.Leaf('ram:AccountName', Pay.Accounts[i].Name);
      w.Close(true);
      w.Open('ram:PayeeSpecifiedCreditorFinancialInstitution');
      w.Leaf('ram:BICID', Pay.Accounts[i].BIC);
      w.Close;
    end;

    w.Close(true);
  end;
end;

procedure WriteCiiSettlement(var w: TCiiWriter; const Inv: TEInvoice);
var
  i: Integer;
  t: TEInvoiceTax;
begin
  w.Open('ram:ApplicableHeaderTradeSettlement');
  w.Leaf('ram:CreditorReferenceID', Inv.Payment.CreditorID);
  w.Leaf('ram:PaymentReference', Inv.Payment.RemittanceInfo);
  w.Leaf('ram:TaxCurrencyCode', Inv.TaxCurrency);
  w.Leaf('ram:InvoiceCurrencyCode', Inv.Currency);
  WriteCiiParty(w, 'ram:PayeeTradeParty', Inv.Payee);
  WriteCiiPaymentMeans(w, Inv.Payment);

  for i := 0 to High(Inv.Taxes) do begin
    t := Inv.Taxes[i];
    w.Open('ram:ApplicableTradeTax');
    w.Num('ram:CalculatedAmount', t.TaxAmount);
    w.Elem('ram:TypeCode', 'VAT', '');
    w.Leaf('ram:ExemptionReason', t.ExemptionReason);
    w.Num('ram:BasisAmount', t.TaxableAmount);
    w.Leaf('ram:CategoryCode', t.Category);
    w.Leaf('ram:ExemptionReasonCode', t.ExemptionReasonCode);

    if Trim(Inv.TaxPointDate) <> '' then begin
      w.Open('ram:TaxPointDate');
      w.Elem('udt:DateString', Date102(Trim(Inv.TaxPointDate)), ' format="102"');
      w.Close;
    end;

    w.Leaf('ram:DueDateTypeCode', CiiDueDateCode(Trim(Inv.TaxPointDateCode)));
    w.Num('ram:RateApplicablePercent', t.Rate);
    w.Close(true);
  end;

  WriteCiiPeriod(w, Inv.PeriodStart, Inv.PeriodEnd);

  for i := 0 to High(Inv.AllowancesCharges) do begin
    WriteCiiAllowanceCharge(w, Inv.AllowancesCharges[i]);
  end;

  w.Open('ram:SpecifiedTradePaymentTerms');
  w.RawLeaf('ram:Description', Inv.PaymentTerms);
  w.Date('ram:DueDateDateTime', Inv.DueDate);
  w.Leaf('ram:DirectDebitMandateID', Inv.Payment.MandateID);
  w.Close;

  w.Open('ram:SpecifiedTradeSettlementHeaderMonetarySummation');
  w.Num('ram:LineTotalAmount', Inv.Totals.LineTotal);
  w.Num('ram:ChargeTotalAmount', Inv.Totals.ChargeTotal);
  w.Num('ram:AllowanceTotalAmount', Inv.Totals.AllowanceTotal);
  w.Num('ram:TaxBasisTotalAmount', Inv.Totals.TaxExclusive);
  w.Num('ram:TaxTotalAmount', Inv.Totals.TaxTotal, Attr('currencyID', Trim(Inv.Currency)));
  w.Num('ram:TaxTotalAmount', Inv.Totals.TaxTotalTaxCurrency, Attr('currencyID', Trim(Inv.TaxCurrency)));
  w.Num('ram:RoundingAmount', Inv.Totals.Rounding);
  w.Num('ram:GrandTotalAmount', Inv.Totals.TaxInclusive);
  w.Num('ram:TotalPrepaidAmount', Inv.Totals.Prepaid);
  w.Num('ram:DuePayableAmount', Inv.Totals.DuePayable);
  w.Close;

  for i := 0 to High(Inv.PrecedingInvoices) do begin
    w.Open('ram:InvoiceReferencedDocument');
    w.Leaf('ram:IssuerAssignedID', Inv.PrecedingInvoices[i].Number);
    w.Date('ram:FormattedIssueDateTime', Inv.PrecedingInvoices[i].Date, 'qdt');
    w.Close(true);
  end;

  w.Open('ram:ReceivableSpecifiedTradeAccountingAccount');
  w.Leaf('ram:ID', Inv.AccountingRef);
  w.Close;
  w.Close(true);
end;

function CiiFromModel(const Inv: TEInvoice): TBytes;
var
  w: TCiiWriter;
  i: Integer;
begin
  w := Default(TCiiWriter);
  w.Line('<?xml version="1.0" encoding="UTF-8"?>');
  w.Open('rsm:CrossIndustryInvoice', ' xmlns:rsm="' + NS_RSM + '" xmlns:ram="' + NS_RAM + '" xmlns:qdt="' + NS_QDT +
    '" xmlns:udt="' + NS_UDT + '"');

  w.Open('rsm:ExchangedDocumentContext');
  w.Open('ram:BusinessProcessSpecifiedDocumentContextParameter');
  w.Leaf('ram:ID', Inv.BusinessProcess);
  w.Close;
  w.Open('ram:GuidelineSpecifiedDocumentContextParameter');
  w.Leaf('ram:ID', Inv.Specification);
  w.Close;
  w.Close(true);

  w.Open('rsm:ExchangedDocument');
  w.Leaf('ram:ID', Inv.Number);
  w.Leaf('ram:TypeCode', Inv.TypeCode);
  w.Date('ram:IssueDateTime', Inv.IssueDate);

  for i := 0 to High(Inv.Notes) do begin
    w.Open('ram:IncludedNote');
    w.Leaf('ram:Content', Inv.Notes[i].Text);
    w.Leaf('ram:SubjectCode', Inv.Notes[i].SubjectCode);
    w.Close(true);
  end;

  w.Close(true);

  w.Open('rsm:SupplyChainTradeTransaction');

  for i := 0 to High(Inv.Lines) do begin
    WriteCiiLine(w, Inv.Lines[i]);
  end;

  WriteCiiAgreement(w, Inv);
  WriteCiiDelivery(w, Inv);
  WriteCiiSettlement(w, Inv);
  w.Close(true);

  w.Close(true);
  result := Utf8Bytes(w.Text);
end;

end.
