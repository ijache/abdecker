{ SPDX-License-Identifier: MIT
  Copyright (c) 2026 Ingo Jache }

unit abdecker.ubl;

{ abdecker - UBL 2.1 Invoice and CreditNote <-> invoice model (internal).
  Not part of the public API: use the unit abdecker. }

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  abdecker, abdecker.read;

{ Reads a UBL Invoice or (Credit = True) CreditNote }
procedure ParseUbl(var r: TModelReader; Credit: Boolean; var Inv: TEInvoice);

implementation

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  abdecker.util;

procedure ReadUblAddress(var r: TModelReader; e: Integer; var a: TEInvoiceAddress);
begin
  a.Line1 := r.Str(e, 'StreetName');
  a.Line2 := r.Str(e, 'AdditionalStreetName');
  a.Line3 := r.Str(e, 'AddressLine/Line');
  a.City := r.Str(e, 'CityName');
  a.PostCode := r.Str(e, 'PostalZone');
  a.Subdivision := r.Str(e, 'CountrySubentity');
  a.Country := r.Str(e, 'Country/IdentificationCode');
end;

{ In UBL the SEPA creditor identifier (BT-90) is a party identification. }
procedure ReadUblParty(var r: TModelReader; e: Integer; var p: TEInvoiceParty;
  var CreditorID: string);
var
  x: Integer;
  v, t: string;
  id: TEInvoiceID;
begin
  if e < 0 then exit;
  p.ElectronicAddress := r.Ident(e, 'EndpointID');
  x := r.First(e, 'PartyIdentification');
  while x >= 0 do begin
    id := r.Ident(x, 'ID');
    if SameText(id.Scheme, 'SEPA') then begin
      CreditorID := id.Value;
    end else begin
      AddID(p.IDs, id);
    end;

    x := r.Next(x);
  end;

  p.TradingName := r.Str(e, 'PartyName/Name');
  ReadUblAddress(r, r.El(e, 'PostalAddress'), p.Address);
  x := r.First(e, 'PartyTaxScheme');
  while x >= 0 do begin
    v := r.Str(x, 'CompanyID');
    t := r.Str(x, 'TaxScheme/ID');
    if SameText(t, 'VAT') then begin
      p.VATID := v;
    end else begin
      p.TaxNumber := v;
    end;

    x := r.Next(x);
  end;

  x := r.El(e, 'PartyLegalEntity');
  p.Name := r.Str(x, 'RegistrationName');
  p.LegalID := r.Ident(x, 'CompanyID');
  p.LegalInfo := r.Str(x, 'CompanyLegalForm');
  x := r.El(e, 'Contact');
  p.Contact.Name := r.Str(x, 'Name');
  p.Contact.Phone := r.Str(x, 'Telephone');
  p.Contact.Email := r.Str(x, 'ElectronicMail');
end;

procedure ReadUblAllowanceCharge(var r: TModelReader; e: Integer; const Grp: string;
  out AC: TEInvoiceAllowanceCharge);
var
  x: Integer;
begin
  AC := Default(TEInvoiceAllowanceCharge);
  AC.IsCharge := SameText(r.Str(e, 'ChargeIndicator'), 'true');
  AC.ReasonCode := r.Str(e, 'AllowanceChargeReasonCode');
  AC.Reason := r.Str(e, 'AllowanceChargeReason');
  AC.Percent := r.Num(e, 'MultiplierFactorNumeric', Grp);
  AC.Amount := r.Num(e, 'Amount', Grp);
  AC.BaseAmount := r.Num(e, 'BaseAmount', Grp);
  x := r.El(e, 'TaxCategory');
  AC.TaxCategory := r.Str(x, 'ID');
  AC.TaxRate := r.Num(x, 'Percent', Grp);
  r.Skip(x, 'TaxScheme/ID');
end;

{ XRechnung/Peppol encode the subject code (BT-21) as '#AAI#text' }
procedure SplitUblNote(const s: string; out Code, Text: string);
var
  i: Integer;
begin
  Code := '';
  Text := s;
  if (Length(s) < 5) or (s[1] <> '#') or (s[5] <> '#') then exit;

  for i := 2 to 4 do begin
    if not (((s[i] >= 'A') and (s[i] <= 'Z')) or ((s[i] >= '0') and (s[i] <= '9'))) then exit;
  end;

  Code := Copy(s, 2, 3);
  Text := Copy(s, 6, MaxInt);
end;

procedure ReadUblLine(var r: TModelReader; e: Integer; Credit: Boolean; out l: TEInvoiceLine);
var
  x, i, q: Integer;
  ac: TEInvoiceAllowanceCharge;
  ia: TEInvoiceItemAttribute;
begin
  l := Default(TEInvoiceLine);
  l.ID := r.Str(e, 'ID');
  x := r.First(e, 'Note');
  while x >= 0 do begin
    AppendText(l.Note, r.TextOf(x));
    x := r.Next(x);
  end;

  if Credit then begin
    q := r.El(e, 'CreditedQuantity');
  end else begin
    q := r.El(e, 'InvoicedQuantity');
  end;

  l.Quantity := r.NumOf(q, 'BT-129');
  l.UnitCode := r.Attr(q, 'unitCode');
  l.NetAmount := r.Num(e, 'LineExtensionAmount', 'BT-131');
  l.AccountingRef := r.Str(e, 'AccountingCost');
  x := r.El(e, 'InvoicePeriod');
  l.PeriodStart := r.DateStr(x, 'StartDate');
  l.PeriodEnd := r.DateStr(x, 'EndDate');
  l.OrderLineRef := r.Str(e, 'OrderLineReference/LineID');
  x := r.El(e, 'DocumentReference');
  l.ObjectID := r.Ident(x, 'ID');
  r.Skip(x, 'DocumentTypeCode');
  x := r.First(e, 'AllowanceCharge');
  while x >= 0 do begin
    ReadUblAllowanceCharge(r, x, 'BG-27/28', ac);
    AddAC(l.AllowancesCharges, ac);
    x := r.Next(x);
  end;

  i := r.El(e, 'Item');
  l.ItemDescription := r.Str(i, 'Description');
  l.ItemName := r.Str(i, 'Name');
  l.BuyerItemID := r.Str(i, 'BuyersItemIdentification/ID');
  l.SellerItemID := r.Str(i, 'SellersItemIdentification/ID');
  l.StandardItemID := r.Ident(i, 'StandardItemIdentification/ID');
  l.OriginCountry := r.Str(i, 'OriginCountry/IdentificationCode');
  x := r.First(i, 'CommodityClassification');
  while x >= 0 do begin
    AddID(l.Classifications, r.IdentOf(r.El(x, 'ItemClassificationCode'), 'listID'));
    x := r.Next(x);
  end;

  x := r.El(i, 'ClassifiedTaxCategory');
  l.TaxCategory := r.Str(x, 'ID');
  l.TaxRate := r.Num(x, 'Percent', 'BT-152');
  r.Skip(x, 'TaxScheme/ID');
  x := r.First(i, 'AdditionalItemProperty');
  while x >= 0 do begin
    ia.Name := r.Str(x, 'Name');
    ia.Value := r.Str(x, 'Value');
    SetLength(l.Attributes, Length(l.Attributes) + 1);
    l.Attributes[High(l.Attributes)] := ia;
    x := r.Next(x);
  end;

  i := r.El(e, 'Price');
  l.NetPrice := r.Num(i, 'PriceAmount', 'BT-146');
  q := r.El(i, 'BaseQuantity');
  l.BaseQuantity := r.NumOf(q, 'BT-149');
  l.BaseQuantityUnit := r.Attr(q, 'unitCode');
  x := r.El(i, 'AllowanceCharge');
  r.Skip(x, 'ChargeIndicator');
  l.PriceDiscount := r.Num(x, 'Amount', 'BT-147');
  l.GrossPrice := r.Num(x, 'BaseAmount', 'BT-148');
end;

{ Lines and their sub-lines (XRechnung extension), flattened in document order }
procedure ReadUblLines(var r: TModelReader; p: Integer; Credit: Boolean; const ElemName,
  ParentID: string; var Lines: TEInvoiceLines);
var
  x: Integer;
  line: TEInvoiceLine;
begin
  x := r.First(p, ElemName);
  while x >= 0 do begin
    ReadUblLine(r, x, Credit, line);
    line.ParentID := ParentID;
    SetLength(Lines, Length(Lines) + 1);
    Lines[High(Lines)] := line;

    if Credit then begin
      ReadUblLines(r, x, Credit, 'SubCreditNoteLine', line.ID, Lines);
    end else begin
      ReadUblLines(r, x, Credit, 'SubInvoiceLine', line.ID, Lines);
    end;

    x := r.Next(x);
  end;
end;

procedure ParseUbl(var r: TModelReader; Credit: Boolean; var Inv: TEInvoice);
var
  x, y, b: Integer;
  v, dummy: string;
  note: TEInvoiceNote;
  ref: TEInvoiceReference;
  docu: TEInvoiceDocument;
  acc: TEInvoiceAccount;
  ac: TEInvoiceAllowanceCharge;
  tax: TEInvoiceTax;
begin
  Inv.Specification := r.Str(0, 'CustomizationID');
  Inv.BusinessProcess := r.Str(0, 'ProfileID');
  Inv.Number := r.Str(0, 'ID');
  Inv.IssueDate := r.DateStr(0, 'IssueDate');
  Inv.DueDate := r.DateStr(0, 'DueDate');

  if Credit then begin
    Inv.TypeCode := r.Str(0, 'CreditNoteTypeCode');
  end else begin
    Inv.TypeCode := r.Str(0, 'InvoiceTypeCode');
  end;

  x := r.First(0, 'Note');
  while x >= 0 do begin
    SplitUblNote(r.TextOf(x), note.SubjectCode, note.Text);
    SetLength(Inv.Notes, Length(Inv.Notes) + 1);
    Inv.Notes[High(Inv.Notes)] := note;
    x := r.Next(x);
  end;

  Inv.TaxPointDate := r.DateStr(0, 'TaxPointDate');
  Inv.Currency := r.Str(0, 'DocumentCurrencyCode');
  Inv.TaxCurrency := r.Str(0, 'TaxCurrencyCode');
  Inv.AccountingRef := r.Str(0, 'AccountingCost');
  Inv.BuyerReference := r.Str(0, 'BuyerReference');
  x := r.El(0, 'InvoicePeriod');
  Inv.PeriodStart := r.DateStr(x, 'StartDate');
  Inv.PeriodEnd := r.DateStr(x, 'EndDate');
  Inv.TaxPointDateCode := r.Str(x, 'DescriptionCode');
  x := r.El(0, 'OrderReference');
  Inv.OrderRef := r.Str(x, 'ID');
  Inv.SalesOrderRef := r.Str(x, 'SalesOrderID');
  x := r.First(0, 'BillingReference');
  while x >= 0 do begin
    y := r.El(x, 'InvoiceDocumentReference');
    ref.Number := r.Str(y, 'ID');
    ref.Date := r.DateStr(y, 'IssueDate');
    SetLength(Inv.PrecedingInvoices, Length(Inv.PrecedingInvoices) + 1);
    Inv.PrecedingInvoices[High(Inv.PrecedingInvoices)] := ref;
    x := r.Next(x);
  end;

  Inv.DespatchAdviceRef := r.Str(0, 'DespatchDocumentReference/ID');
  Inv.ReceivingAdviceRef := r.Str(0, 'ReceiptDocumentReference/ID');
  Inv.TenderRef := r.Str(0, 'OriginatorDocumentReference/ID');
  Inv.ContractRef := r.Str(0, 'ContractDocumentReference/ID');
  x := r.First(0, 'AdditionalDocumentReference');
  while x >= 0 do begin
    if r.Str(x, 'DocumentTypeCode') = '130' then begin
      Inv.InvoicedObject := r.Ident(x, 'ID');
    end else begin
      docu := Default(TEInvoiceDocument);
      docu.ID := r.Str(x, 'ID');
      docu.Description := r.Str(x, 'DocumentDescription');
      y := r.El(x, 'Attachment');
      b := r.El(y, 'EmbeddedDocumentBinaryObject');
      if b >= 0 then begin
        docu.Content := DecodeBase64(r.TextOf(b));
        docu.MimeType := r.Attr(b, 'mimeCode');
        docu.FileName := r.Attr(b, 'filename');
      end;

      docu.URI := r.Str(y, 'ExternalReference/URI');
      SetLength(Inv.Documents, Length(Inv.Documents) + 1);
      Inv.Documents[High(Inv.Documents)] := docu;
    end;

    x := r.Next(x);
  end;

  Inv.ProjectRef := r.Str(0, 'ProjectReference/ID');

  ReadUblParty(r, r.El(0, 'AccountingSupplierParty/Party'), Inv.Seller, Inv.Payment.CreditorID);
  ReadUblParty(r, r.El(0, 'AccountingCustomerParty/Party'), Inv.Buyer, dummy);
  // payee and tax representative carry their name in PartyName
  ReadUblParty(r, r.El(0, 'PayeeParty'), Inv.Payee, Inv.Payment.CreditorID);

  if Inv.Payee.Name = '' then begin
    Inv.Payee.Name := Inv.Payee.TradingName;
    Inv.Payee.TradingName := '';
  end;

  ReadUblParty(r, r.El(0, 'TaxRepresentativeParty'), Inv.TaxRepresentative, dummy);

  if Inv.TaxRepresentative.Name = '' then begin
    Inv.TaxRepresentative.Name := Inv.TaxRepresentative.TradingName;
    Inv.TaxRepresentative.TradingName := '';
  end;

  x := r.El(0, 'Delivery');
  Inv.Delivery.Date := r.DateStr(x, 'ActualDeliveryDate');
  y := r.El(x, 'DeliveryLocation');
  Inv.Delivery.LocationID := r.Ident(y, 'ID');
  ReadUblAddress(r, r.El(y, 'Address'), Inv.Delivery.Address);
  Inv.Delivery.PartyName := r.Str(x, 'DeliveryParty/PartyName/Name');

  x := r.First(0, 'PaymentMeans');
  while x >= 0 do begin
    y := r.El(x, 'PaymentMeansCode');
    SetLength(Inv.Payment.MeansCodes, Length(Inv.Payment.MeansCodes) + 1);
    Inv.Payment.MeansCodes[High(Inv.Payment.MeansCodes)] := r.TextOf(y);

    if Inv.Payment.MeansCode = '' then begin
      Inv.Payment.MeansCode := r.TextOf(y);
      Inv.Payment.MeansText := r.Attr(y, 'name');
    end;

    v := r.Str(x, 'PaymentID');
    if (v <> '') and (Inv.Payment.RemittanceInfo = '') then Inv.Payment.RemittanceInfo := v;
    v := r.DateStr(x, 'PaymentDueDate');
    if (v <> '') and (Inv.DueDate = '') then Inv.DueDate := v;
    y := r.El(x, 'PayeeFinancialAccount');
    if y >= 0 then begin
      acc.IBAN := r.Str(y, 'ID');
      acc.Name := r.Str(y, 'Name');
      acc.BIC := r.Str(y, 'FinancialInstitutionBranch/ID');
      SetLength(Inv.Payment.Accounts, Length(Inv.Payment.Accounts) + 1);
      Inv.Payment.Accounts[High(Inv.Payment.Accounts)] := acc;
    end;

    y := r.El(x, 'CardAccount');
    if y >= 0 then begin
      Inv.Payment.CardNumber := r.Str(y, 'PrimaryAccountNumberID');
      Inv.Payment.CardHolder := r.Str(y, 'HolderName');
      r.Skip(y, 'NetworkID');
    end;

    y := r.El(x, 'PaymentMandate');
    if y >= 0 then begin
      Inv.Payment.MandateID := r.Str(y, 'ID');
      Inv.Payment.DebitedAccount := r.Str(y, 'PayerFinancialAccount/ID');
    end;

    x := r.Next(x);
  end;

  x := r.First(0, 'PaymentTerms');
  while x >= 0 do begin
    AppendText(Inv.PaymentTerms, r.RawStr(x, 'Note'));
    x := r.Next(x);
  end;

  x := r.First(0, 'AllowanceCharge');
  while x >= 0 do begin
    ReadUblAllowanceCharge(r, x, 'BG-20/21', ac);
    AddAC(Inv.AllowancesCharges, ac);
    x := r.Next(x);
  end;

  x := r.First(0, 'TaxTotal');
  while x >= 0 do begin
    y := r.El(x, 'TaxAmount');
    v := r.Attr(y, 'currencyID');
    if (v <> '') and (v <> Inv.Currency) and (v = Inv.TaxCurrency) then begin
      Inv.Totals.TaxTotalTaxCurrency := r.NumOf(y, 'BT-111');
    end else begin
      Inv.Totals.TaxTotal := r.NumOf(y, 'BT-110');
    end;

    y := r.First(x, 'TaxSubtotal');
    while y >= 0 do begin
      tax := Default(TEInvoiceTax);
      tax.TaxableAmount := r.Num(y, 'TaxableAmount', 'BT-116');
      tax.TaxAmount := r.Num(y, 'TaxAmount', 'BT-117');
      b := r.El(y, 'TaxCategory');
      tax.Category := r.Str(b, 'ID');
      tax.Rate := r.Num(b, 'Percent', 'BT-119');
      tax.ExemptionReasonCode := r.Str(b, 'TaxExemptionReasonCode');
      tax.ExemptionReason := r.Str(b, 'TaxExemptionReason');
      r.Skip(b, 'TaxScheme/ID');
      SetLength(Inv.Taxes, Length(Inv.Taxes) + 1);
      Inv.Taxes[High(Inv.Taxes)] := tax;
      y := r.Next(y);
    end;

    x := r.Next(x);
  end;

  x := r.El(0, 'LegalMonetaryTotal');
  Inv.Totals.LineTotal := r.Num(x, 'LineExtensionAmount', 'BT-106');
  Inv.Totals.TaxExclusive := r.Num(x, 'TaxExclusiveAmount', 'BT-109');
  Inv.Totals.TaxInclusive := r.Num(x, 'TaxInclusiveAmount', 'BT-112');
  Inv.Totals.AllowanceTotal := r.Num(x, 'AllowanceTotalAmount', 'BT-107');
  Inv.Totals.ChargeTotal := r.Num(x, 'ChargeTotalAmount', 'BT-108');
  Inv.Totals.Prepaid := r.Num(x, 'PrepaidAmount', 'BT-113');
  Inv.Totals.Rounding := r.Num(x, 'PayableRoundingAmount', 'BT-114');
  Inv.Totals.DuePayable := r.Num(x, 'PayableAmount', 'BT-115');

  if Credit then begin
    ReadUblLines(r, 0, Credit, 'CreditNoteLine', '', Inv.Lines);
  end else begin
    ReadUblLines(r, 0, Credit, 'InvoiceLine', '', Inv.Lines);
  end;
end;

end.
