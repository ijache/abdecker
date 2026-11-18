{ SPDX-License-Identifier: MIT
  Copyright (c) 2026 Ingo Jache }

program abdeckertests;

{ abdecker - test runner.

  1. unit tests through the public API (synthetic XML and PDF)
  2. corpus run: every PDF/XML below testdata/external is analysed and the
     results are compared with tests/golden/corpus.txt
     (abdeckertests --update writes the current results as new reference) }

{$IFDEF MSWINDOWS}
  {$APPTYPE CONSOLE}
{$ENDIF}
{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

uses
{$IFDEF FPC}
  {$IFDEF MSWINDOWS} Windows, {$ENDIF} SysUtils, Classes, zstream,
{$ELSE}
  Winapi.Windows, System.SysUtils, System.Classes, System.ZLib, System.Diagnostics,
{$ENDIF}
  abdecker in '..\source\abdecker.pas',
  abdecker.util,  // DumpModel
  abdecker.json,  // JsonParse
  abdecker.qr,    // QrEncode (--qr)
  abdecker.payment;  // PaymentInfo (GiroCode corpus)

{$IFDEF FPC}
type
  // what the tests use of the Delphi RTL
  TZCompressionStream = TCompressionStream;

  TStopwatch = record
    T0, T1: QWord;
    class function StartNew: TStopwatch; static;
    procedure Stop;
    function ElapsedMilliseconds: Int64;
  end;

class function TStopwatch.StartNew: TStopwatch;
begin
  result.T0 := GetTickCount64;
  result.T1 := result.T0;
end;

procedure TStopwatch.Stop;
begin
  T1 := GetTickCount64;
end;

function TStopwatch.ElapsedMilliseconds: Int64;
begin
  result := Int64(T1 - T0);
end;
{$ENDIF}

const
  ResultNames: array[TAbResult] of string = ('OK', 'NoInvoice', 'UnknownFormat',
    'FileError', 'BrokenPDF', 'BrokenXML', 'Encrypted', 'Unsupported', 'InvalidData', 'InternalError');
  SyntaxNames: array[TEInvoiceSyntax] of string = ('-', 'CII', 'UBL-Invoice', 'UBL-CreditNote', 'ZUGFeRD1');
  ProfileNames: array[TEInvoiceProfile] of string = ('-', 'MINIMUM', 'BASICWL', 'BASIC', 'COMFORT',
    'EN16931', 'EXTENDED', 'XRECHNUNG', 'PEPPOL');
  ContainerNames: array[TEInvoiceContainer] of string = ('-', 'XML', 'PDF');

var
  Passed, Failed: Integer;
  Root: string;

procedure Check(Cond: Boolean; const Name: string; const Detail: string = '');
begin
  if Cond then begin
    Inc(Passed);
  end else begin
    Inc(Failed);
    Writeln('  FEHLER: ', Name, ' ', Detail);
  end;
end;

function U8(const s: string): TBytes;
begin
  result := TEncoding.UTF8.GetBytes(s);
end;

function HasMsg(const Msgs: TAbMessages; const Code: string): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(Msgs) do begin
    if Msgs[i].Code = Code then exit(true);
  end;
  result := false;
end;

{ text of the first message with this code, '' if none }
function MsgText(const Msgs: TAbMessages; const Code: string): string;
var
  i: Integer;
begin
  for i := 0 to High(Msgs) do begin
    if Msgs[i].Code = Code then exit(Msgs[i].Text);
  end;
  result := '';
end;

function MsgCodes(const Msgs: TAbMessages): string;
var
  i: Integer;
begin
  result := '';
  for i := 0 to High(Msgs) do begin
    if i > 0 then result := result + ',';
    result := result + Msgs[i].Code;
  end;
end;

{ ---- synthetic test data ---- }

function CII(const Guideline, SellerName: string): string;
begin
  result :=
    '<?xml version="1.0" encoding="UTF-8"?>'#10 +
    '<!-- Testrechnung -->'#10 +
    '<rsm:CrossIndustryInvoice xmlns:rsm="urn:un:unece:uncefact:data:standard:CrossIndustryInvoice:100"' +
    ' xmlns:ram="urn:un:unece:uncefact:data:standard:ReusableAggregateBusinessInformationEntity:100"' +
    ' xmlns:udt="urn:un:unece:uncefact:data:standard:UnqualifiedDataType:100">'#10 +
    ' <rsm:ExchangedDocumentContext><ram:GuidelineSpecifiedDocumentContextParameter>' +
    '<ram:ID>' + Guideline + '</ram:ID></ram:GuidelineSpecifiedDocumentContextParameter></rsm:ExchangedDocumentContext>'#10 +
    ' <rsm:ExchangedDocument><ram:ID>R-2024-001</ram:ID><ram:TypeCode>380</ram:TypeCode>' +
    '<ram:IssueDateTime><udt:DateTimeString format="102">20240115</udt:DateTimeString></ram:IssueDateTime></rsm:ExchangedDocument>'#10 +
    ' <rsm:SupplyChainTradeTransaction>'#10 +
    '  <ram:ApplicableHeaderTradeAgreement>' +
    '<ram:SellerTradeParty><ram:Name>' + SellerName + '</ram:Name></ram:SellerTradeParty>' +
    '<ram:BuyerTradeParty><ram:Name><![CDATA[Käufer <AG>]]></ram:Name></ram:BuyerTradeParty>' +
    '</ram:ApplicableHeaderTradeAgreement>'#10 +
    '  <ram:ApplicableHeaderTradeSettlement><ram:InvoiceCurrencyCode>EUR</ram:InvoiceCurrencyCode>' +
    '<ram:SpecifiedTradeSettlementHeaderMonetarySummation><ram:GrandTotalAmount>119.00</ram:GrandTotalAmount>' +
    '<ram:DuePayableAmount>119.00</ram:DuePayableAmount></ram:SpecifiedTradeSettlementHeaderMonetarySummation>' +
    '</ram:ApplicableHeaderTradeSettlement>'#10 +
    ' </rsm:SupplyChainTradeTransaction>'#10 +
    '</rsm:CrossIndustryInvoice>'#10;
end;

const
  UBL =
    '<Invoice xmlns="urn:oasis:names:specification:ubl:schema:xsd:Invoice-2"' +
    ' xmlns:cbc="urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2"' +
    ' xmlns:cac="urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2">' +
    '<cbc:CustomizationID>urn:cen.eu:en16931:2017#compliant#urn:xeinkauf.de:kosit:xrechnung_3.0</cbc:CustomizationID>' +
    '<cbc:ID>4711</cbc:ID><cbc:IssueDate>2024-02-01</cbc:IssueDate><cbc:InvoiceTypeCode>380</cbc:InvoiceTypeCode>' +
    '<cbc:DocumentCurrencyCode>EUR</cbc:DocumentCurrencyCode>' +
    '<cac:AccountingSupplierParty><cac:Party><cac:PartyLegalEntity><cbc:RegistrationName>Seller</cbc:RegistrationName>' +
    '</cac:PartyLegalEntity></cac:Party></cac:AccountingSupplierParty>' +
    '<cac:LegalMonetaryTotal><cbc:TaxInclusiveAmount currencyID="EUR">10.00</cbc:TaxInclusiveAmount>' +
    '<cbc:PayableAmount currencyID="EUR">10.00</cbc:PayableAmount></cac:LegalMonetaryTotal></Invoice>';

  XMP =
    '<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>'#10 +
    '<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'#10 +
    '<rdf:Description rdf:about="" xmlns:pdfaid="http://www.aiim.org/pdfa/ns/id/">' +
    '<pdfaid:part>3</pdfaid:part><pdfaid:conformance>B</pdfaid:conformance></rdf:Description>'#10 +
    '<rdf:Description rdf:about="" xmlns:fx="urn:factur-x:pdfa:CrossIndustryDocument:invoice:1p0#"' +
    ' fx:DocumentType="INVOICE" fx:DocumentFileName="factur-x.xml" fx:Version="1.0" fx:ConformanceLevel="EN 16931"/>'#10 +
    '</rdf:RDF></x:xmpmeta>'#10 +
    '<?xpacket end="w"?>';

function Deflate(const Src: TBytes): TBytes;
var
  dst: TBytesStream;
  z: TZCompressionStream;
begin
  dst := TBytesStream.Create;
  try
    z := TZCompressionStream.Create(clDefault, dst);
    try
      if Length(Src) > 0 then begin
        z.WriteBuffer(Src[0], Length(Src));
      end;
    finally
      z.Free;
    end;
    result := Copy(dst.Bytes, 0, dst.Size);
  finally
    dst.Free;
  end;
end;

{ Minimal one-page PDF with an embedded invoice. BreakXRef shifts all xref
  offsets to force the reconstruction path. }
function BuildPdf(const Xml: TBytes; WithFile, Compress, BreakXRef: Boolean): TBytes;
var
  s: TBytesStream;
  offs: array[1..6] of Int64;
  data, meta: TBytes;
  xRefPos: Int64;
  i, shift: Integer;

  procedure W(const Str: string);
  var
    a: AnsiString;
  begin
    a := AnsiString(Str);
    if a <> '' then begin
      s.WriteBuffer(a[1], Length(a));
    end;
  end;

  procedure WB(const Bytes: TBytes);
  begin
    if Length(Bytes) > 0 then begin
      s.WriteBuffer(Bytes[0], Length(Bytes));
    end;
  end;

begin
  s := TBytesStream.Create;
  try
    W('%PDF-1.7'#10);
    offs[1] := s.Position;
    W('1 0 obj'#10'<< /Type /Catalog /Pages 2 0 R /Metadata 6 0 R');
    if WithFile then begin
      W(' /Names << /EmbeddedFiles << /Names [(factur-x.xml) 4 0 R] >> >> /AF [4 0 R]');
    end;
    W(' >>'#10'endobj'#10);
    offs[2] := s.Position;
    W('2 0 obj'#10'<< /Type /Pages /Kids [3 0 R] /Count 1 >>'#10'endobj'#10);
    offs[3] := s.Position;
    W('3 0 obj'#10'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] >>'#10'endobj'#10);
    offs[4] := s.Position;
    W('4 0 obj'#10'<< /Type /Filespec /F (factur-x.xml) /UF <FEFF0066006100630074007500720'
      + '02D0078002E0078006D006C> /AFRelationship /Alternative /EF << /F 5 0 R >> >>'#10'endobj'#10);
    data := Xml;
    if Compress then data := Deflate(Xml);
    offs[5] := s.Position;
    W('5 0 obj'#10'<< /Type /EmbeddedFile /Subtype /text#2Fxml /Params << /Size ' +
      IntToStr(Length(Xml)) + ' >> /Length ' + IntToStr(Length(data)));
    if Compress then begin
      W(' /Filter /FlateDecode');
    end;
    W(' >>'#10'stream'#10);
    WB(data);
    W(#10'endstream'#10'endobj'#10);
    meta := U8(XMP);
    offs[6] := s.Position;
    W('6 0 obj'#10'<< /Type /Metadata /Subtype /XML /Length ' + IntToStr(Length(meta)) + ' >>'#10'stream'#10);
    WB(meta);
    W(#10'endstream'#10'endobj'#10);
    xRefPos := s.Position;
    if BreakXRef then shift := 7 else shift := 0;
    W('xref'#10'0 7'#10'0000000000 65535 f'#13#10);
    for i := 1 to 6 do begin
      W(Format('%.10d 00000 n'#13#10, [offs[i] + shift]));
    end;
    W('trailer'#10'<< /Size 7 /Root 1 0 R >>'#10'startxref'#10 + IntToStr(xRefPos) + #10'%%EOF'#10);
    result := Copy(s.Bytes, 0, s.Size);
  finally
    s.Free;
  end;
end;

{ ---- unit tests ---- }

procedure TestXml;
var
  info: TEInvoiceInfo;
  msgs: TAbMessages;
  r: TAbResult;
begin
  Writeln('XML');
  r := TAbdecker.InfoFromBytes(U8(CII('urn:cen.eu:en16931:2017', 'M&amp;M Gr&#252;n &#xFC;')), info, msgs);
  Check(r = abOK, 'CII lesen', TAbdecker.ResultText(r) + ' ' + MsgCodes(msgs));
  Check(info.Container = eicontXML, 'CII Container');
  Check(info.Syntax = eisynCII, 'CII Syntax');
  Check(info.Profile = eiprofEN16931, 'CII Profil');
  Check(info.InvoiceNumber = 'R-2024-001', 'CII Nummer', info.InvoiceNumber);
  Check(info.IssueDate = '2024-01-15', 'CII Datum (Format 102)', info.IssueDate);
  Check(info.SellerName = 'M&M Grün ü', 'Entities', info.SellerName);
  Check(info.BuyerName = 'Käufer <AG>', 'CDATA', info.BuyerName);
  Check(info.GrandTotal = '119.00', 'CII Betrag', info.GrandTotal);
  Check(Length(msgs) = 0, 'CII ohne Meldungen', MsgCodes(msgs));

  r := TAbdecker.InfoFromBytes(U8(UBL), info, msgs);
  Check(r = abOK, 'UBL lesen', TAbdecker.ResultText(r));
  Check(info.Syntax = eisynUBLInvoice, 'UBL Syntax (Default-Namensraum)');
  Check(info.Profile = eiprofXRechnung, 'UBL Profil');
  Check(info.XRechnungVersion = '3.0', 'XRechnung-Version', info.XRechnungVersion);
  Check(info.SellerName = 'Seller', 'UBL Verkäufer');
  Check(info.DuePayable = '10.00', 'UBL Zahlbetrag');

  r := TAbdecker.InfoFromBytes(U8(CII('urn:factur-x.eu:1p0:minimum', 'X')), info, msgs);
  Check((r = abOK) and (info.Profile = eiprofMinimum), 'Profil MINIMUM');
  Check(HasMsg(msgs, 'ZF-NOT-EINVOICE'), 'MINIMUM-Warnung');

  TAbdecker.InfoFromBytes(U8(CII('urn:cen.eu:en16931:2017#conformant#urn:factur-x.eu:1p0:extended', 'X')), info, msgs);
  Check(info.Profile = eiprofExtended, 'Profil EXTENDED');
  TAbdecker.InfoFromBytes(U8(CII('urn:cen.eu:en16931:2017#compliant#urn:factur-x.eu:1p0:basic', 'X')), info, msgs);
  Check(info.Profile = eiprofBasic, 'Profil BASIC');

  r := TAbdecker.InfoFromBytes(TEncoding.Unicode.GetPreamble + TEncoding.Unicode.GetBytes(UBL), info, msgs);
  Check((r = abOK) and (info.Syntax = eisynUBLInvoice), 'UTF-16 mit BOM', TAbdecker.ResultText(r));

  r := TAbdecker.InfoFromBytes(U8('<a>'#10'<b></a>'), info, msgs);
  Check(r = abBrokenXML, 'Kaputtes XML erkannt', TAbdecker.ResultText(r));
  Check((Length(msgs) > 0) and (Pos('line 2', msgs[0].Text) > 0), 'Fehler mit Zeilennummer', MsgCodes(msgs));

  r := TAbdecker.InfoFromBytes(U8('<!DOCTYPE foo [<!ENTITY x "y">]><foo/>'), info, msgs);
  Check(r = abUnknownFormat, 'Unbekanntes XML (mit DOCTYPE)', TAbdecker.ResultText(r));

  r := TAbdecker.InfoFromBytes(U8('Hallo Welt'), info, msgs);
  Check(r = abUnknownFormat, 'Weder PDF noch XML');

  r := TAbdecker.InfoFromBytes(nil, info, msgs);
  Check(r = abUnknownFormat, 'Leere Eingabe');
end;

procedure TestPdf;
var
  info: TEInvoiceInfo;
  msgs: TAbMessages;
  r: TAbResult;
  xml, got: TBytes;
  name: string;
  compress: Boolean;
begin
  Writeln('PDF');
  xml := U8(CII('urn:cen.eu:en16931:2017', 'Muster GmbH'));
  for compress := false to true do begin
    r := TAbdecker.InfoFromBytes(BuildPdf(xml, true, compress, false), info, msgs);
    Check(r = abOK, 'PDF lesen, komprimiert=' + BoolToStr(compress, true), TAbdecker.ResultText(r) + ' ' + MsgCodes(msgs));
    Check(info.Container = eicontPDF, 'PDF Container');
    Check(info.PDFVersion = '1.7', 'PDF-Version', info.PDFVersion);
    Check(info.Profile = eiprofEN16931, 'PDF Profil');
    Check(info.InvoiceFileName = 'factur-x.xml', 'Dateiname (UTF-16BE)', info.InvoiceFileName);
    Check((info.PDFAPart = '3') and (info.PDFAConformance = 'B'), 'XMP pdfaid', info.PDFAPart + info.PDFAConformance);
    Check(info.XMPConformanceLevel = 'EN 16931', 'XMP fx-Attribute', info.XMPConformanceLevel);
    Check((Length(info.Attachments) = 1) and info.Attachments[0].InAF, 'Anhang im /AF');
    Check((Length(info.Attachments) = 1) and (info.Attachments[0].MimeType = 'text/xml'), 'MIME-Typ (#2F)');
    Check(Length(msgs) = 0, 'PDF ohne Meldungen', MsgCodes(msgs));

    r := TAbdecker.ExtractXMLFromBytes(BuildPdf(xml, true, compress, false), got, name, msgs);
    Check((r = abOK) and (Length(got) = Length(xml)) and CompareMem(@got[0], @xml[0], Length(xml)),
      'XML unverändert extrahiert');
  end;

  r := TAbdecker.InfoFromBytes(BuildPdf(xml, true, true, true), info, msgs);
  Check(r = abOK, 'Kaputte xref', TAbdecker.ResultText(r));
  Check(HasMsg(msgs, 'PDF-XREF'), 'Warnung bei rekonstruierter Struktur', MsgCodes(msgs));

  r := TAbdecker.InfoFromBytes(BuildPdf(xml, false, false, false), info, msgs);
  Check(r = abNoInvoice, 'PDF ohne Rechnung (verwaister Anhang zählt nicht)', TAbdecker.ResultText(r));

  TAbdecker.InfoFromBytes(BuildPdf(U8(CII('urn:factur-x.eu:1p0:minimum', 'X')), true, false, false), info, msgs);
  Check(HasMsg(msgs, 'ZF-XMP-PROFILE'), 'XMP-Profil passt nicht', MsgCodes(msgs));

  r := TAbdecker.ExtractXMLFromBytes(U8(UBL), got, name, msgs);
  Check(r = abUnsupported, 'Extract aus XML abgelehnt');

  r := TAbdecker.InfoFromBytes(U8('%PDF-1.4'#10'kaputt'), info, msgs);
  Check(r = abBrokenPDF, 'Kaputtes PDF', TAbdecker.ResultText(r));
end;

procedure TestDecimal;
var
  a, b: TAbDecimal;
begin
  Writeln('Dezimal');
  a := TAbDecimal.Parse(' 12.50 ');
  Check(a.Present and a.Valid and (a.Value = 1250) and (a.Scale = 2), 'Parse 12.50');
  Check(a.ToString = '12.50', 'ToString behält Nachkommastellen', a.ToString);
  Check(TAbDecimal.Parse('-0.05').ToString = '-0.05', 'Negativ < 1', TAbDecimal.Parse('-0.05').ToString);
  Check(TAbDecimal.Parse('+7').ToString = '7', 'Plus-Zeichen');
  Check(TAbDecimal.Parse('5.').Valid, '"5." ist gültig');
  b := TAbDecimal.Parse('');
  Check(not b.Present and b.Valid and b.IsZero, 'Leer = abwesend, gültig, null');
  Check(not TAbDecimal.Parse('12,50').Valid, 'Komma ungültig');
  Check(not TAbDecimal.Parse('1e5').Valid, 'Exponent ungültig');
  Check(not TAbDecimal.Parse('.').Valid, 'Nur Punkt ungültig');
  Check(not TAbDecimal.Parse('1234567890123456789').Valid, '19 Stellen ungültig');
  Check(TAbDecimal.Parse('10.000000000000000000').Valid, 'Abschließende Nullen zählen nicht');
  Check(TAbDecimal.Parse('10.000000000000000000').Equals(TAbDecimal.Parse('10')), 'Abschließende Nullen: Wert');
  Check(TAbDecimal.Parse('0000000000000000000001.5').Valid, 'Führende Nullen zählen nicht');
  Check(a.Add(TAbDecimal.Parse('0.505')).ToString = '13.005', 'Addition', a.Add(TAbDecimal.Parse('0.505')).ToString);
  Check(a.Sub(TAbDecimal.Parse('20')).ToString = '-7.50', 'Subtraktion');
  Check(a.Add(b).ToString = '12.50', 'Addition mit abwesendem Wert');
  Check(TAbDecimal.Parse('3.5').Mul(TAbDecimal.Parse('1.25')).ToString = '4.375', 'Multiplikation');
  Check(TAbDecimal.Parse('2.345').Rounded(2).ToString = '2.35', 'Runden 2.345');
  Check(TAbDecimal.Parse('-2.345').Rounded(2).ToString = '-2.35', 'Runden -2.345 (weg von null)');
  Check(TAbDecimal.Parse('2.344').Rounded(2).ToString = '2.34', 'Runden 2.344');
  Check(TAbDecimal.Parse('5').Rounded(2).ToString = '5', 'Runden ohne Nachkommastellen');
  Check(TAbDecimal.Parse('10').Divide(TAbDecimal.Parse('3'), 4).ToString = '3.3333', 'Division');
  Check(TAbDecimal.Parse('2').Divide(TAbDecimal.Parse('3'), 2).ToString = '0.67', 'Division rundet');
  Check(not TAbDecimal.Parse('1').Divide(TAbDecimal.Parse('0'), 2).Valid, 'Division durch null');
  Check(TAbDecimal.Parse('19.00').Equals(TAbDecimal.Parse('19')), 'Gleichheit unabhängig von Skala');
  Check(TAbDecimal.Parse('19.001').Compare(TAbDecimal.Parse('19')) = 1, 'Vergleich');
  Check(TAbDecimal.Parse('12.500').Normalized.ToString = '12.5', 'Normalisieren');
  Check(not TAbDecimal.Parse('999999999999999999').Mul(TAbDecimal.Parse('10')).Valid, 'Überlauf erkannt');
  Check(not TAbDecimal.Parse('x').Add(a).Valid, 'Ungültig bleibt ungültig');
  b := Default(TAbDecimal);
  Check(a.Add(b).Valid and (a.Add(b).ToString = '12.50') and (b.ToString = ''), 'Default() zählt als abwesend');
end;

const
  CIIFull =
    '<rsm:CrossIndustryInvoice xmlns:rsm="urn:un:unece:uncefact:data:standard:CrossIndustryInvoice:100"' +
    ' xmlns:ram="urn:un:unece:uncefact:data:standard:ReusableAggregateBusinessInformationEntity:100"' +
    ' xmlns:udt="urn:un:unece:uncefact:data:standard:UnqualifiedDataType:100">' +
    '<rsm:ExchangedDocumentContext><ram:GuidelineSpecifiedDocumentContextParameter><ram:ID>urn:cen.eu:en16931:2017#compliant#urn:xeinkauf.de:kosit:xrechnung_3.0</ram:ID>' +
    '</ram:GuidelineSpecifiedDocumentContextParameter></rsm:ExchangedDocumentContext>' +
    '<rsm:ExchangedDocument><ram:ID>R1</ram:ID><ram:TypeCode>380</ram:TypeCode>' +
    '<ram:IssueDateTime><udt:DateTimeString format="102">20240301</udt:DateTimeString></ram:IssueDateTime>' +
    '<ram:IncludedNote><ram:Content>Danke</ram:Content><ram:SubjectCode>AAI</ram:SubjectCode></ram:IncludedNote></rsm:ExchangedDocument>' +
    '<rsm:SupplyChainTradeTransaction>' +
    '<ram:IncludedSupplyChainTradeLineItem><ram:AssociatedDocumentLineDocument><ram:LineID>1</ram:LineID></ram:AssociatedDocumentLineDocument>' +
    '<ram:SpecifiedTradeProduct><ram:Name>Beratung</ram:Name></ram:SpecifiedTradeProduct>' +
    '<ram:SpecifiedLineTradeAgreement><ram:NetPriceProductTradePrice><ram:ChargeAmount>95.00</ram:ChargeAmount></ram:NetPriceProductTradePrice></ram:SpecifiedLineTradeAgreement>' +
    '<ram:SpecifiedLineTradeDelivery><ram:BilledQuantity unitCode="HUR">10</ram:BilledQuantity></ram:SpecifiedLineTradeDelivery>' +
    '<ram:SpecifiedLineTradeSettlement><ram:ApplicableTradeTax><ram:TypeCode>VAT</ram:TypeCode><ram:CategoryCode>S</ram:CategoryCode>' +
    '<ram:RateApplicablePercent>19</ram:RateApplicablePercent></ram:ApplicableTradeTax>' +
    '<ram:SpecifiedTradeSettlementLineMonetarySummation><ram:LineTotalAmount>950.00</ram:LineTotalAmount></ram:SpecifiedTradeSettlementLineMonetarySummation>' +
    '</ram:SpecifiedLineTradeSettlement></ram:IncludedSupplyChainTradeLineItem>' +
    '<ram:ApplicableHeaderTradeAgreement><ram:BuyerReference>04011000-12345-34</ram:BuyerReference>' +
    '<ram:SellerTradeParty><ram:Name>Muster GmbH</ram:Name>' +
    '<ram:PostalTradeAddress><ram:PostcodeCode>12345</ram:PostcodeCode><ram:CityName>Berlin</ram:CityName><ram:CountryID>DE</ram:CountryID></ram:PostalTradeAddress>' +
    '<ram:URIUniversalCommunication><ram:URIID schemeID="EM">rechnung@muster.de</ram:URIID></ram:URIUniversalCommunication>' +
    '<ram:SpecifiedTaxRegistration><ram:ID schemeID="VA">DE123456789</ram:ID></ram:SpecifiedTaxRegistration>' +
    '<ram:SpecifiedTaxRegistration><ram:ID schemeID="FC">12/345/67890</ram:ID></ram:SpecifiedTaxRegistration></ram:SellerTradeParty>' +
    '<ram:BuyerTradeParty><ram:Name>Amt</ram:Name></ram:BuyerTradeParty></ram:ApplicableHeaderTradeAgreement>' +
    '<ram:ApplicableHeaderTradeDelivery><ram:ActualDeliverySupplyChainEvent><ram:OccurrenceDateTime>' +
    '<udt:DateTimeString format="102">20240228</udt:DateTimeString></ram:OccurrenceDateTime></ram:ActualDeliverySupplyChainEvent></ram:ApplicableHeaderTradeDelivery>' +
    '<ram:ApplicableHeaderTradeSettlement><ram:InvoiceCurrencyCode>EUR</ram:InvoiceCurrencyCode>' +
    '<ram:SpecifiedTradeSettlementPaymentMeans><ram:TypeCode>58</ram:TypeCode><ram:PayeePartyCreditorFinancialAccount>' +
    '<ram:IBANID>DE02120300000000202051</ram:IBANID></ram:PayeePartyCreditorFinancialAccount></ram:SpecifiedTradeSettlementPaymentMeans>' +
    '<ram:ApplicableTradeTax><ram:CalculatedAmount>180.50</ram:CalculatedAmount><ram:TypeCode>VAT</ram:TypeCode>' +
    '<ram:BasisAmount>950.00</ram:BasisAmount><ram:CategoryCode>S</ram:CategoryCode><ram:DueDateTypeCode>5</ram:DueDateTypeCode>' +
    '<ram:RateApplicablePercent>19</ram:RateApplicablePercent></ram:ApplicableTradeTax>' +
    '<ram:SpecifiedTradePaymentTerms><ram:Description>#SKONTO#TAGE=14#PROZENT=2.00#</ram:Description></ram:SpecifiedTradePaymentTerms>' +
    '<ram:SpecifiedTradeSettlementHeaderMonetarySummation><ram:LineTotalAmount>950.00</ram:LineTotalAmount>' +
    '<ram:TaxBasisTotalAmount>950.00</ram:TaxBasisTotalAmount><ram:TaxTotalAmount currencyID="EUR">180.50</ram:TaxTotalAmount>' +
    '<ram:GrandTotalAmount>1130.50</ram:GrandTotalAmount><ram:DuePayableAmount>1130,50</ram:DuePayableAmount>' +
    '</ram:SpecifiedTradeSettlementHeaderMonetarySummation></ram:ApplicableHeaderTradeSettlement>' +
    '</rsm:SupplyChainTradeTransaction><ram:Extra>?</ram:Extra></rsm:CrossIndustryInvoice>';

procedure TestModel;
var
  inv: TEInvoice;
  msgs: TAbMessages;
  r: TAbResult;
begin
  Writeln('Modell');
  r := TAbdecker.LoadFromBytes(U8(CIIFull), inv, msgs);
  Check(r = abOK, 'CII laden', TAbdecker.ResultText(r) + ' ' + MsgCodes(msgs));
  Check(inv.Info.Profile = eiprofXRechnung, 'Info im Modell');
  Check((inv.Number = 'R1') and (inv.IssueDate = '2024-03-01'), 'BT-1, BT-2');
  Check((Length(inv.Notes) = 1) and (inv.Notes[0].SubjectCode = 'AAI') and (inv.Notes[0].Text = 'Danke'), 'BG-1');
  Check(inv.BuyerReference = '04011000-12345-34', 'BT-10');
  Check((inv.Seller.VATID = 'DE123456789') and (inv.Seller.TaxNumber = '12/345/67890'), 'BT-31, BT-32');
  Check((inv.Seller.ElectronicAddress.Value = 'rechnung@muster.de') and (inv.Seller.ElectronicAddress.Scheme = 'EM'), 'BT-34');
  Check(inv.Seller.Address.City = 'Berlin', 'BT-37');
  Check(inv.Delivery.Date = '2024-02-28', 'BT-72');
  Check(inv.TaxPointDateCode = '3', 'BT-8 auf UNTDID 2005 abgebildet', inv.TaxPointDateCode);
  Check((Length(inv.Payment.Accounts) = 1) and (inv.Payment.Accounts[0].IBAN = 'DE02120300000000202051'), 'BT-84');
  Check(inv.PaymentTerms = '#SKONTO#TAGE=14#PROZENT=2.00#', 'BT-20');
  Check((Length(inv.Taxes) = 1) and (inv.Taxes[0].TaxAmount.ToString = '180.50') and (inv.Taxes[0].Rate.ToString = '19'), 'BG-23');
  Check(inv.Totals.TaxInclusive.ToString = '1130.50', 'BT-112');
  Check(not inv.Totals.DuePayable.Valid and HasMsg(msgs, 'NUMBER'), 'BT-115 ungültig gemeldet', MsgCodes(msgs));
  Check(Length(inv.Lines) = 1, 'Eine Position');
  if Length(inv.Lines) = 1 then begin
    Check((inv.Lines[0].ID = '1') and (inv.Lines[0].ItemName = 'Beratung'), 'BT-126, BT-153');
    Check((inv.Lines[0].Quantity.ToString = '10') and (inv.Lines[0].UnitCode = 'HUR'), 'BT-129, BT-130');
    Check(inv.Lines[0].NetPrice.Mul(inv.Lines[0].Quantity).Equals(inv.Lines[0].NetAmount), 'Menge x Preis = Nettobetrag');
    Check((inv.Lines[0].TaxCategory = 'S') and (inv.Lines[0].TaxRate.ToString = '19'), 'BT-151, BT-152');
  end;
  Check((Length(inv.Unmapped) = 1) and (inv.Unmapped[0] = 'Extra = ?'), 'Nicht abgebildetes Element gemeldet',
    IntToStr(Length(inv.Unmapped)));

  r := TAbdecker.LoadFromBytes(U8(UBL), inv, msgs);
  Check(r = abOK, 'UBL laden');
  Check((inv.Number = '4711') and (inv.Seller.Name = 'Seller') and (inv.Totals.DuePayable.ToString = '10.00'), 'UBL-Felder');

  r := TAbdecker.LoadFromBytes(BuildPdf(U8(CIIFull), true, true, false), inv, msgs);
  Check((r = abOK) and (inv.Info.Container = eicontPDF) and (inv.Number = 'R1'), 'Modell aus PDF');
end;

{ ---- embedding ---- }

const
  XMP_PDFA2 =
    '<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>'#10 +
    '<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'#10 +
    '<rdf:Description rdf:about="" xmlns:pdfaid="http://www.aiim.org/pdfa/ns/id/">' +
    '<pdfaid:part>2</pdfaid:part><pdfaid:conformance>B</pdfaid:conformance></rdf:Description>'#10 +
    '<rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title><rdf:Alt>' +
    '<rdf:li xml:lang="x-default">Testdokument</rdf:li></rdf:Alt></dc:title></rdf:Description>'#10 +
    '</rdf:RDF></x:xmpmeta>'#10'<?xpacket end="w"?>';

  // PDF/A-1 as attributes, with an extension schema list for another schema
  XMP_PDFA1_EXT =
    '<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>'#10 +
    '<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'#10 +
    '<rdf:Description rdf:about="" xmlns:pdfaid="http://www.aiim.org/pdfa/ns/id/" pdfaid:part="1" pdfaid:conformance="B"/>'#10 +
    '<rdf:Description rdf:about="" xmlns:pdfaExtension="http://www.aiim.org/pdfa/ns/extension/"' +
    ' xmlns:pdfaSchema="http://www.aiim.org/pdfa/ns/schema#"><pdfaExtension:schemas><rdf:Bag>' +
    '<rdf:li rdf:parseType="Resource"><pdfaSchema:schema>Other</pdfaSchema:schema>' +
    '<pdfaSchema:namespaceURI>urn:other#</pdfaSchema:namespaceURI><pdfaSchema:prefix>o</pdfaSchema:prefix></rdf:li>' +
    '</rdf:Bag></pdfaExtension:schemas></rdf:Description>'#10 +
    '</rdf:RDF></x:xmpmeta>'#10'<?xpacket end="w"?>';

{ Test PDF without invoice. XRefStm: cross-reference stream, catalog and the
  destinations inside an object stream (PDF 1.5). Other: an attachment
  'other.txt' in the name tree and in /AF, plus /Dests in the names. }
function BuildTestPdf(const Meta: string; XRefStm, Other: Boolean): TBytes;
var
  s: TBytesStream;
  objs: array[1..7] of string;
  offs: array[0..11] of Int64;
  inStm: array[1..7] of Boolean;
  i, n: Integer;
  hdr, body, metaU: string;
  x: TBytes;

  procedure W(const Str: string);
  var
    a: TBytes;
  begin
    a := TEncoding.UTF8.GetBytes(Str);
    if Length(a) > 0 then begin
      s.WriteBuffer(a[0], Length(a));
    end;
  end;

  procedure Row(t: Byte; F2: Int64; F3: Integer);
  var
    k: Integer;
  begin
    n := Length(x);
    SetLength(x, n + 7);
    x[n] := t;
    for k := 0 to 3 do begin
      x[n + 1 + k] := Byte(F2 shr (8 * (3 - k)));
    end;
    x[n + 5] := Byte(F3 shr 8);
    x[n + 6] := Byte(F3);
  end;

begin
  objs[1] := '<< /Type /Catalog /Pages 2 0 R';
  if Meta <> '' then objs[1] := objs[1] + ' /Metadata 4 0 R';
  if Other then begin
    objs[1] := objs[1] + ' /Names << /Dests 6 0 R /EmbeddedFiles << /Names [(other.txt) 5 0 R] >> >> /AF [5 0 R]';
  end;
  objs[1] := objs[1] + ' /Lang (de-DE) /ViewerPreferences << /DisplayDocTitle true >> >>';
  objs[2] := '<< /Type /Pages /Kids [3 0 R] /Count 1 >>';
  objs[3] := '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595.28 841.89] >>';
  metaU := Meta;
  if Meta <> '' then begin
    objs[4] := '<< /Type /Metadata /Subtype /XML /Length ' + IntToStr(Length(TEncoding.UTF8.GetBytes(metaU))) +
      ' >>'#10'stream'#10 + metaU + #10'endstream';
  end else begin
    objs[4] := 'null';
  end;
  objs[5] := '<< /Type /Filespec /F (other.txt) /UF (other.txt) /AFRelationship /Supplement /EF << /F 7 0 R >> >>';
  objs[6] := '<< /Chapter1 [3 0 R /Fit] >>';
  objs[7] := '<< /Type /EmbeddedFile /Length 11 >>'#10'stream'#10'hello world'#10'endstream';
  for i := 1 to 7 do begin
    inStm[i] := XRefStm and ((i = 1) or (i = 6));
  end;
  s := TBytesStream.Create;
  try
    if XRefStm then begin
      W('%PDF-1.5'#10);
    end else begin
      W('%PDF-1.4'#10);
    end;
    for i := 1 to 7 do begin
      if not inStm[i] then begin
        offs[i] := s.Position;
        W(IntToStr(i) + ' 0 obj'#10 + objs[i] + #10'endobj'#10);
      end;
    end;
    if not XRefStm then begin
      offs[0] := s.Position;
      W('xref'#10'0 8'#10'0000000000 65535 f'#13#10);
      for i := 1 to 7 do begin
        W(Format('%.10d 00000 n'#13#10, [offs[i]]));
      end;
      W('trailer'#10'<< /Size 8 /Root 1 0 R /ID [<0123456789abcdef0123456789abcdef> ' +
        '<0123456789abcdef0123456789abcdef>] >>'#10'startxref'#10 + IntToStr(offs[0]) + #10'%%EOF'#10);
    end else begin
      // object stream 10 with objects 1 and 6
      body := objs[1] + ' ' + objs[6];
      hdr := '1 0 6 ' + IntToStr(Length(objs[1]) + 1) + ' ';
      offs[10] := s.Position;
      W('10 0 obj'#10'<< /Type /ObjStm /N 2 /First ' + IntToStr(Length(hdr)) + ' /Length ' +
        IntToStr(Length(hdr) + Length(body)) + ' >>'#10'stream'#10 + hdr + body + #10'endstream'#10'endobj'#10);
      offs[11] := s.Position;
      x := nil;
      Row(0, 0, 65535);
      Row(2, 10, 0);
      for i := 2 to 5 do begin
        Row(1, offs[i], 0);
      end;
      Row(2, 10, 1);
      Row(1, offs[7], 0);
      Row(0, 0, 0);
      Row(0, 0, 0);
      Row(1, offs[10], 0);
      Row(1, offs[11], 0);
      W('11 0 obj'#10'<< /Type /XRef /Size 12 /W [1 4 2] /Root 1 0 R /ID [<0123456789abcdef0123456789abcdef> ' +
        '<0123456789abcdef0123456789abcdef>] /Length ' + IntToStr(Length(x)) + ' >>'#10'stream'#10);
      s.WriteBuffer(x[0], Length(x));
      W(#10'endstream'#10'endobj'#10'startxref'#10 + IntToStr(offs[11]) + #10'%%EOF'#10);
    end;
    result := Copy(s.Bytes, 0, s.Size);
  finally
    s.Free;
  end;
end;

function BytesPos(const Hay, Needle: TBytes): Integer;
var
  i: Integer;
begin
  for i := 0 to Length(Hay) - Length(Needle) do begin
    if CompareMem(@Hay[i], @Needle[0], Length(Needle)) then exit(i);
  end;
  result := -1;
end;

function Contains(const Data: TBytes; const s: string): Boolean;
begin
  result := Pos(s, TEncoding.ANSI.GetString(Data)) > 0;
end;

procedure TestEmbed;
var
  pdf, xml, outPdf, got, twice: TBytes;
  msgs: TAbMessages;
  r: TAbResult;
  info: TEInvoiceInfo;
  name: string;
  stm, oth: Boolean;
  tail: string;
begin
  Writeln('Einbetten');
  xml := U8(CIIFull);
  for stm := false to true do begin
    for oth := false to true do begin
      name := Format(' (Xref-Stream=%s, anderer Anhang=%s)', [BoolToStr(stm, true), BoolToStr(oth, true)]);
      pdf := BuildTestPdf(XMP_PDFA2, stm, oth);
      r := TAbdecker.InfoFromBytes(pdf, info, msgs);
      Check(r = abNoInvoice, 'Test-PDF ohne Rechnung' + name, TAbdecker.ResultText(r) + ' ' + MsgCodes(msgs));
      r := TAbdecker.EmbedBytes(pdf, xml, outPdf, msgs);
      Check(r = abOK, 'Einbetten' + name, TAbdecker.ResultText(r) + ' ' + MsgCodes(msgs));
      if r <> abOK then continue;
      Check(CompareMem(@outPdf[0], @pdf[0], Length(pdf)), 'Original unverändert vorne' + name);
      tail := TEncoding.ANSI.GetString(Copy(outPdf, Length(pdf), MaxInt));
      Check((Pos('/Type /XRef', tail) > 0) = stm, 'Xref-Form wie im Original' + name);
      Check(Pos('/Prev ', tail) > 0, 'Update verweist auf das alte Xref' + name);
      r := TAbdecker.InfoFromBytes(outPdf, info, msgs);
      Check(r = abOK, 'Ergebnis wird erkannt' + name, MsgCodes(msgs));
      Check(Length(msgs) = 0, 'Ergebnis ohne Meldungen' + name, MsgCodes(msgs));
      Check(info.InvoiceFileName = 'xrechnung.xml', 'Dateiname xrechnung.xml (Profil XRECHNUNG)' + name, info.InvoiceFileName);
      Check((info.PDFAPart = '3') and (info.PDFAConformance = 'B'), 'PDF/A-2 wird PDF/A-3' + name,
        info.PDFAPart + info.PDFAConformance);
      Check(info.XMPConformanceLevel = 'XRECHNUNG', 'XMP fx:ConformanceLevel' + name, info.XMPConformanceLevel);
      Check(Contains(outPdf, 'Testdokument'), 'Alte XMP-Angaben bleiben' + name);
      Check(Contains(outPdf, '/Lang (de-DE)') or Contains(outPdf, '/Lang <64652d4445>'), 'Katalogeinträge bleiben' + name);
      if oth then begin
        Check(Length(info.Attachments) = 2, 'Vorhandener Anhang bleibt' + name, IntToStr(Length(info.Attachments)));
        Check(Contains(outPdf, '/Dests 6 0 R'), 'Sprungziele bleiben' + name);
      end;
      r := TAbdecker.ExtractXMLFromBytes(outPdf, got, name, msgs);
      Check((r = abOK) and (Length(got) = Length(xml)) and CompareMem(@got[0], @xml[0], Length(xml)),
        'XML Byte für Byte unverändert');
      // embedding a second time is refused
      r := TAbdecker.EmbedBytes(outPdf, xml, twice, msgs);
      Check((r = abUnsupported) and HasMsg(msgs, 'EMBED-EXISTS'), 'Zweites Einbetten abgelehnt');
    end;
  end;

  // no metadata, no PDF/A
  r := TAbdecker.EmbedBytes(BuildTestPdf('', false, false), xml, outPdf, msgs);
  Check((r = abOK) and HasMsg(msgs, 'EMBED-NO-PDFA'), 'Kein PDF/A: eingebettet mit Warnung', MsgCodes(msgs));
  TAbdecker.InfoFromBytes(outPdf, info, msgs);
  Check((info.XMPConformanceLevel = 'XRECHNUNG') and (info.PDFAPart = ''), 'Neues XMP ohne PDF/A-Kennung');

  // PDF/A-1 with another extension schema: part 3, our schema added to the bag
  r := TAbdecker.EmbedBytes(BuildTestPdf(XMP_PDFA1_EXT, false, false), xml, outPdf, msgs);
  Check((r = abOK) and HasMsg(msgs, 'EMBED-PDFA1'), 'PDF/A-1: Hinweis', MsgCodes(msgs));
  TAbdecker.InfoFromBytes(outPdf, info, msgs);
  Check((info.PDFAPart = '3') and (Length(msgs) = 0), 'PDF/A-1 wird als PDF/A-3 gekennzeichnet', info.PDFAPart + ' ' + MsgCodes(msgs));
  Check(Contains(outPdf, 'urn:other#') and (Pos('<pdfaExtension:schemas>', TEncoding.ANSI.GetString(outPdf)) =
    LastDelimiter('<', Copy(TEncoding.ANSI.GetString(outPdf), 1, Pos('<pdfaExtension:schemas>', TEncoding.ANSI.GetString(outPdf))))),
    'Erweiterungsschema in die vorhandene Liste');

  // the PDF was ZUGFeRD before: XMP has fx already (attribute form), no attachment
  r := TAbdecker.EmbedBytes(BuildTestPdf(XMP, false, false), U8(CII('urn:cen.eu:en16931:2017', 'X')), outPdf, msgs);
  Check(r = abOK, 'Ehemaliges ZUGFeRD-PDF', MsgCodes(msgs));
  TAbdecker.InfoFromBytes(outPdf, info, msgs);
  Check((info.XMPConformanceLevel = 'EN 16931') and (info.InvoiceFileName = 'factur-x.xml') and (Length(msgs) = 0),
    'Vorhandene fx-Angaben aktualisiert', info.XMPConformanceLevel + ' ' + MsgCodes(msgs));

  // UBL: converted to CII; Peppol BIS as EN 16931; content outside EN 16931 lost with a warning
  r := TAbdecker.EmbedBytes(BuildTestPdf('', false, false), U8(UBL), outPdf, msgs);
  Check((r = abOK) and HasMsg(msgs, 'EMBED-UBL') and not HasMsg(msgs, 'EMBED-UBL-LOST'), 'UBL als CII eingebettet',
    MsgCodes(msgs));
  TAbdecker.ExtractXMLFromBytes(outPdf, got, name, msgs);
  TAbdecker.InfoFromBytes(got, info, msgs);
  Check((info.Syntax = eisynCII) and (info.Profile = eiprofXRechnung) and (name = 'xrechnung.xml'),
    'UBL: eingebettet ist CII (XRechnung)', TAbdecker.SyntaxCode(info.Syntax) + ' ' + name);
  r := TAbdecker.EmbedBytes(BuildTestPdf('', false, false), U8(StringReplace(UBL,
    'urn:xeinkauf.de:kosit:xrechnung_3.0', 'urn:fdc:peppol.eu:2017:poacc:billing:3.0', [])), outPdf, msgs);
  Check((r = abOK) and HasMsg(msgs, 'EMBED-PEPPOL'), 'Peppol-UBL als EN 16931', MsgCodes(msgs));
  TAbdecker.InfoFromBytes(outPdf, info, msgs);
  Check((info.XMPConformanceLevel = 'EN 16931') and (info.InvoiceFileName = 'factur-x.xml') and
    (info.GuidelineID = 'urn:cen.eu:en16931:2017'), 'Peppol-UBL: Profil EN 16931',
    info.XMPConformanceLevel + ' ' + info.GuidelineID);
  r := TAbdecker.EmbedBytes(BuildTestPdf('', false, false), U8(StringReplace(UBL,
    '<cac:AccountingSupplierParty>', '<cac:PrepaidPayment><cbc:ID>P-1</cbc:ID></cac:PrepaidPayment>' +
    '<cac:AccountingSupplierParty>', [])), outPdf, msgs);
  Check((r = abOK) and HasMsg(msgs, 'EMBED-UBL-LOST') and (Pos('PrepaidPayment/ID', MsgText(msgs, 'EMBED-UBL-LOST')) > 0),
    'UBL: nicht abgebildeter Inhalt als Warnung', MsgCodes(msgs));

  // refusals
  r := TAbdecker.EmbedBytes(BuildTestPdf('', false, false), BuildTestPdf('', false, false), outPdf, msgs);
  Check((r = abUnsupported) and HasMsg(msgs, 'EMBED-NOT-XML'), 'PDF als Rechnung abgelehnt', MsgCodes(msgs));
  r := TAbdecker.EmbedBytes(xml, xml, outPdf, msgs);
  Check((r = abUnsupported) and HasMsg(msgs, 'EMBED-NOT-PDF'), 'XML als PDF abgelehnt', MsgCodes(msgs));
  r := TAbdecker.EmbedBytes(BuildPdf(xml, true, false, false), xml, outPdf, msgs);
  Check((r = abUnsupported) and HasMsg(msgs, 'EMBED-EXISTS'), 'PDF mit Rechnung abgelehnt', MsgCodes(msgs));
  r := TAbdecker.EmbedBytes(BuildPdf(xml, false, false, true), xml, outPdf, msgs);
  Check(r = abBrokenPDF, 'PDF mit kaputter Struktur abgelehnt', TAbdecker.ResultText(r) + ' ' + MsgCodes(msgs));
  r := TAbdecker.EmbedBytes(BuildTestPdf('', false, false), U8(CII('urn:cen.eu:en16931:2017', 'X')), outPdf, msgs);
  Check((r = abOK) and HasMsg(msgs, 'EMBED-CHECK'), 'Prüffehler der Rechnung als Hinweis', MsgCodes(msgs));
end;

{ ---- plausibility check: a valid XRechnung built in code, then mutations ---- }

function D(const s: string): TAbDecimal;
begin
  result := TAbDecimal.Parse(s);
end;

function ValidInvoice: TEInvoice;
begin
  result := Default(TEInvoice);
  result.Info.Container := eicontXML;
  result.Info.Syntax := eisynCII;
  result.Info.Profile := eiprofXRechnung;
  result.Info.XRechnungVersion := '3.0';
  result.Specification := 'urn:cen.eu:en16931:2017#compliant#urn:xeinkauf.de:kosit:xrechnung_3.0';
  result.BusinessProcess := 'urn:fdc:peppol.eu:2017:poacc:billing:01:1.0';
  result.Number := 'R-1';
  result.IssueDate := '2024-03-01';
  result.TypeCode := '380';
  result.Currency := 'EUR';
  result.BuyerReference := '04011000-12345-34';
  result.PaymentTerms := 'Zahlbar innerhalb 14 Tagen';
  result.Seller.Name := 'Muster GmbH';
  result.Seller.VATID := 'DE123456789';
  result.Seller.ElectronicAddress.Value := 'rechnung@muster.de';
  result.Seller.ElectronicAddress.Scheme := 'EM';
  result.Seller.Address.Line1 := 'Hauptstr. 1';
  result.Seller.Address.City := 'Berlin';
  result.Seller.Address.PostCode := '10115';
  result.Seller.Address.Country := 'DE';
  result.Seller.Contact.Name := 'Erika Muster';
  result.Seller.Contact.Phone := '+49 30 123456';
  result.Seller.Contact.Email := 'erika@muster.de';
  result.Buyer.Name := 'Stadtverwaltung';
  result.Buyer.ElectronicAddress.Value := 'eingang@stadt.de';
  result.Buyer.ElectronicAddress.Scheme := 'EM';
  result.Buyer.Address.City := 'Potsdam';
  result.Buyer.Address.PostCode := '14467';
  result.Buyer.Address.Country := 'DE';
  result.Payment.MeansCode := '58';
  SetLength(result.Payment.MeansCodes, 1);
  result.Payment.MeansCodes[0] := '58';
  SetLength(result.Payment.Accounts, 1);
  result.Payment.Accounts[0].IBAN := 'DE02120300000000202051';
  SetLength(result.Lines, 1);
  result.Lines[0].ID := '1';
  result.Lines[0].ItemName := 'Beratung';
  result.Lines[0].Quantity := D('10');
  result.Lines[0].UnitCode := 'HUR';
  result.Lines[0].NetPrice := D('95.00');
  result.Lines[0].NetAmount := D('950.00');
  result.Lines[0].TaxCategory := 'S';
  result.Lines[0].TaxRate := D('19');
  SetLength(result.Taxes, 1);
  result.Taxes[0].Category := 'S';
  result.Taxes[0].Rate := D('19');
  result.Taxes[0].TaxableAmount := D('950.00');
  result.Taxes[0].TaxAmount := D('180.50');
  result.Totals.LineTotal := D('950.00');
  result.Totals.TaxExclusive := D('950.00');
  result.Totals.TaxTotal := D('180.50');
  result.Totals.TaxInclusive := D('1130.50');
  result.Totals.DuePayable := D('1130.50');
end;

function Codes(const Rep: TAbCheckReport): string;
var
  i: Integer;
begin
  result := '';
  for i := 0 to High(Rep.Messages) do begin
    result := result + Rep.Messages[i].Code + ' ';
  end;
end;

{ Checks Inv and expects exactly the given rule IDs (space separated) }
procedure Expect(const Name: string; const Inv: TEInvoice; const Expected: string);
var
  rep: TAbCheckReport;
  got, e: TStringList;
  i: Integer;
begin
  TAbdecker.Check(Inv, rep);
  got := TStringList.Create;
  e := TStringList.Create;
  try
    got.Sorted := true;
    got.Duplicates := dupIgnore;
    e.Sorted := true;
    e.Duplicates := dupIgnore;
    for i := 0 to High(rep.Messages) do begin
      got.Add(rep.Messages[i].Code);
    end;
    e.DelimitedText := Expected;
    Check(got.CommaText = e.CommaText, Name, 'erwartet [' + e.CommaText + '], erhalten [' + got.CommaText + ']');
  finally
    e.Free;
    got.Free;
  end;
end;

{ status of rule ID in the report: passed, failed, not-applied or absent }
function RuleState(const Rep: TAbCheckReport; const ID: string): string;
var
  i: Integer;
begin
  for i := 0 to High(Rep.Rules) do begin
    if Rep.Rules[i].ID = ID then exit(TAbdecker.RuleStatusCode(Rep.Rules[i].Status));
  end;

  result := 'absent';
end;

function RuleIndex(const Rep: TAbCheckReport; const ID: string): Integer;
var
  i: Integer;
begin
  for i := 0 to High(Rep.Rules) do begin
    if Rep.Rules[i].ID = ID then exit(i);
  end;

  result := -1;
end;

{ a rule failed <=> there is a finding with its ID; '' if consistent, else the first ID that is not }
function RulesInconsistent(const Rep: TAbCheckReport): string;
var
  i, j: Integer;
  found: Boolean;
begin
  result := '';

  for i := 0 to High(Rep.Rules) do begin
    found := false;

    for j := 0 to High(Rep.Messages) do begin
      if (Rep.Messages[j].Origin <> aboFile) and (Rep.Messages[j].Code = Rep.Rules[i].ID) then found := true;
    end;

    if found <> (Rep.Rules[i].Status = arsFailed) then exit(Rep.Rules[i].ID);
  end;

  for j := 0 to High(Rep.Messages) do begin
    if (Rep.Messages[j].Origin <> aboFile) and (RuleState(Rep, Rep.Messages[j].Code) <> 'failed') then begin
      exit(Rep.Messages[j].Code);
    end;
  end;
end;

procedure TestRuleStatus;
var
  inv: TEInvoice;
  rep: TAbCheckReport;
  i, failed: Integer;
  json: string;
begin
  Writeln('Prüfregeln: Status je Regel');
  inv := ValidInvoice;
  TAbdecker.Check(inv, rep);
  failed := 0;

  for i := 0 to High(rep.Rules) do begin
    if rep.Rules[i].Status = arsFailed then Inc(failed);
  end;

  Check((Length(rep.Rules) > 200) and (failed = 0), 'Gültige XRechnung: alle Regeln beider Regelwerke, keine verletzt',
    IntToStr(Length(rep.Rules)) + ' Regeln, ' + IntToStr(failed) + ' verletzt');
  Check((RuleState(rep, 'BR-01') = 'passed') and (RuleState(rep, 'BR-S-08') = 'passed') and
    (RuleState(rep, 'BR-DE-15') = 'passed') and (RuleState(rep, 'BR-CO-10') = 'passed'), 'Zutreffende Regeln: passed');
  Check((RuleState(rep, 'BR-AE-01') = 'not-applied') and (RuleState(rep, 'BR-17') = 'not-applied') and
    (RuleState(rep, 'BR-29') = 'not-applied') and (RuleState(rep, 'BR-64') = 'not-applied'),
    'Regeln ohne Gegenstand: not-applied');
  Check((RuleIndex(rep, 'BR-DE-2') >= 0) and (RuleIndex(rep, 'BR-DE-2') < RuleIndex(rep, 'BR-DE-10')) and
    (RuleIndex(rep, 'BR-65') < RuleIndex(rep, 'BR-AE-01')) and (RuleIndex(rep, 'BR-DE-31') < RuleIndex(rep, 'BR-DEC-01')),
    'Reihenfolge: Zahlen nach Wert');
  Check(rep.Rules[RuleIndex(rep, 'PEPPOL-EN16931-R120')].Origin = aboOfficial, 'R120 bei XRechnung: offiziell angewandt');

  inv := ValidInvoice;
  inv.BuyerReference := '';
  TAbdecker.Check(inv, rep);
  Check(RuleState(rep, 'BR-DE-15') = 'failed', 'BR-DE-15 verletzt: failed');
  Check(RulesInconsistent(rep) = '', 'Befunde und Status passen zusammen', RulesInconsistent(rep));
  json := TAbdecker.CheckToJson('x.xml', abOK, inv, rep, true);
  Check((Pos('"rules": [', json) > 0) and
    (Pos('{"id": "BR-DE-15", "status": "failed", "origin": "official"}', json) > 0) and
    (Pos('"rules"', TAbdecker.CheckToJson('x.xml', abOK, inv, rep)) = 0), 'JSON: "rules" nur auf Wunsch');

  inv := ValidInvoice;
  inv.PeriodStart := '2024-02-01';
  inv.PeriodEnd := '2024-02-29';
  TAbdecker.Check(inv, rep);
  Check(RuleState(rep, 'BR-29') = 'passed', 'BR-29 mit Leistungszeitraum: passed');
  inv.PeriodEnd := '2024-01-31';
  TAbdecker.Check(inv, rep);
  Check(RuleState(rep, 'BR-29') = 'failed', 'BR-29 Ende vor Beginn: failed');

  inv := ValidInvoice;
  inv.Lines[0].TaxCategory := 'AE';
  inv.Lines[0].TaxRate := D('0');
  inv.Taxes[0].Category := 'AE';
  inv.Taxes[0].Rate := D('0');
  inv.Taxes[0].TaxAmount := D('0');
  inv.Taxes[0].ExemptionReason := 'Reverse Charge';
  inv.Buyer.VATID := 'ATU12345675';
  inv.Totals.TaxTotal := D('0');
  inv.Totals.TaxInclusive := D('950.00');
  inv.Totals.DuePayable := D('950.00');
  TAbdecker.Check(inv, rep);
  Check((RuleState(rep, 'BR-AE-01') = 'passed') and (RuleState(rep, 'BR-AE-02') = 'passed') and
    (RuleState(rep, 'BR-AE-10') = 'passed') and (RuleState(rep, 'BR-S-01') = 'not-applied'),
    'Reverse Charge: BR-AE angewandt, BR-S nicht', Codes(rep));

  inv := ValidInvoice;
  inv.Lines[0].NetAmount := D('949.00');
  inv.Totals.LineTotal := D('949.00');
  inv.Totals.TaxExclusive := D('949.00');
  inv.Taxes[0].TaxableAmount := D('949.00');
  inv.Totals.TaxInclusive := D('1129.50');
  inv.Totals.DuePayable := D('1129.50');
  inv.Info.Profile := eiprofEN16931;
  inv.Specification := 'urn:cen.eu:en16931:2017';
  TAbdecker.Check(inv, rep);
  Check((RuleState(rep, 'BR-DE-15') = 'absent') and (RuleState(rep, 'PEPPOL-EN16931-R010') = 'absent') and
    (RuleState(rep, 'PEPPOL-EN16931-R120') = 'failed') and
    (rep.Rules[RuleIndex(rep, 'PEPPOL-EN16931-R120')].Origin = aboExtra),
    'EN 16931: keine XRechnung-Regeln, R120 als zusätzliche Prüfung');
  Check(RulesInconsistent(rep) = '', 'EN 16931: Befunde und Status passen zusammen', RulesInconsistent(rep));

  inv := ValidInvoice;
  inv.Info.Profile := eiprofMinimum;
  inv.Lines := nil;
  TAbdecker.Check(inv, rep);
  Check(Length(rep.Rules) = 0, 'MINIMUM: keine Regeln');
end;

procedure TestCheck;
var
  inv: TEInvoice;
  rep: TAbCheckReport;
begin
  Writeln('Prüfregeln');
  inv := ValidInvoice;
  Check(TAbdecker.Check(inv, rep), 'Gültige XRechnung ohne Fehler', Codes(rep));
  Check(Length(rep.NotChecked) = 0, 'Gültige XRechnung: alles geprüft', IntToStr(Length(rep.NotChecked)));
  Check((Length(rep.RuleSets) = 2) and (rep.RuleSets[1] = 'XRechnung 3.0'), 'Regelwerke EN 16931 + XRechnung');
  Expect('Gültig', inv, '');

  inv := ValidInvoice; inv.Number := '';
  Expect('BR-02 Rechnungsnummer', inv, 'BR-02');
  inv := ValidInvoice; inv.Seller.Address.Country := '';
  Expect('BR-09 Land Verkäufer', inv, 'BR-09');
  inv := ValidInvoice; inv.Lines[0].NetPrice := D('-1');
  Expect('BR-27 negativer Preis', inv, 'BR-27 PEPPOL-EN16931-R120');
  inv := ValidInvoice; inv.Totals.LineTotal := D('951.00');
  Expect('BR-CO-10 Summe Positionen', inv, 'BR-CO-10 BR-CO-13');
  inv := ValidInvoice; inv.Totals.DuePayable := D('1130.00');
  Expect('BR-CO-16 Zahlbetrag', inv, 'BR-CO-16');
  inv := ValidInvoice; inv.Totals.Prepaid := D('130.50'); inv.Totals.DuePayable := D('1000.00');
  Expect('Anzahlung korrekt verrechnet', inv, '');
  inv := ValidInvoice; inv.Taxes[0].TaxAmount := D('181.49'); inv.Totals.TaxTotal := D('181.49');
  inv.Totals.TaxInclusive := D('1131.49'); inv.Totals.DuePayable := D('1131.49');
  Expect('Steuer innerhalb der Toleranz (< 1)', inv, '');
  inv := ValidInvoice; inv.Taxes[0].TaxAmount := D('181.50'); inv.Totals.TaxTotal := D('181.50');
  inv.Totals.TaxInclusive := D('1131.50'); inv.Totals.DuePayable := D('1131.50');
  Expect('BR-CO-17 Steuer daneben', inv, 'BR-CO-17 BR-S-09');
  inv := ValidInvoice; inv.Totals.TaxTotal := D('180.00');
  Expect('BR-CO-14/15 Steuersumme', inv, 'BR-CO-14 BR-CO-15');
  inv := ValidInvoice; inv.Totals.LineTotal := D('950.001');
  Expect('BR-DEC-09 Nachkommastellen', inv, 'BR-DEC-09 BR-CO-10');
  inv := ValidInvoice; inv.Totals.LineTotal := D('950.000');
  Expect('Abschließende Nullen sind keine Nachkommastellen', inv, '');
  inv := ValidInvoice; inv.Seller.VATID := 'XX123';
  Expect('BR-CO-09 USt-IdNr.', inv, 'BR-CO-09');
  inv := ValidInvoice; inv.Seller.VATID := 'EL123456789';
  Expect('EL für Griechenland', inv, '');
  inv := ValidInvoice; inv.Lines[0].UnitCode := 'Stück';
  Expect('BR-CL-23 Einheit', inv, 'BR-CL-23');
  inv := ValidInvoice; inv.Currency := 'EUX';
  Expect('BR-CL-04 Währung', inv, 'BR-CL-04');
  inv := ValidInvoice; inv.TypeCode := '999';
  Expect('BR-CL-01 Rechnungsart', inv, 'BR-CL-01 BR-DE-17');
  inv := ValidInvoice; inv.Lines[0].TaxRate := D('7');
  Expect('BR-S-08 Satz ohne Positionen', inv, 'BR-S-08');
  inv := ValidInvoice; inv.Taxes[0].ExemptionReason := 'befreit';
  Expect('BR-S-10 kein Befreiungsgrund bei S', inv, 'BR-S-10');
  inv := ValidInvoice; inv.Lines[0].TaxCategory := 'E'; inv.Lines[0].TaxRate := D('0');
  inv.Taxes[0].Category := 'E'; inv.Taxes[0].Rate := D('0'); inv.Taxes[0].TaxAmount := D('0');
  inv.Totals.TaxTotal := D('0'); inv.Totals.TaxInclusive := D('950.00'); inv.Totals.DuePayable := D('950.00');
  Expect('BR-E-10 Befreiungsgrund fehlt', inv, 'BR-E-10');
  inv.Taxes[0].ExemptionReasonCode := 'VATEX-EU-132';
  Expect('Steuerbefreit mit Grund', inv, '');
  inv := ValidInvoice; inv.Seller.VATID := '';
  Expect('BR-S-02, BR-CO-26, BR-DE-16 ohne Steuernummer', inv, 'BR-S-02 BR-CO-26 BR-DE-16');
  inv := ValidInvoice; inv.Seller.VATID := ''; inv.Seller.TaxNumber := '12/345/67890';
  SetLength(inv.Seller.IDs, 1); inv.Seller.IDs[0].Value := '4000001123452';
  Expect('Steuernummer statt USt-IdNr.', inv, '');
  inv := ValidInvoice; inv.PaymentTerms := '#SKONTO#TAGE=14#PROZENT=2.00#'#10;
  Expect('Skonto korrekt', inv, '');
  inv := ValidInvoice; inv.PaymentTerms := '#SKONTO#TAGE=14#PROZENT=2.00#';
  Expect('BR-DE-18 Skonto ohne Zeilenumbruch', inv, 'BR-DE-18');
  inv := ValidInvoice; inv.PaymentTerms := '#SKONTO#TAGE=14#PROZENT=2#'#10;
  Expect('BR-DE-18 Prozent ohne zwei Nachkommastellen', inv, 'BR-DE-18');
  inv := ValidInvoice; inv.PaymentTerms := 'Skonto:'#10'#SKONTO#TAGE=7#PROZENT=3.00#BASISBETRAG=100.00#'#10'sonst 30 Tage';
  Expect('Skonto mit Basisbetrag und Text', inv, '');
  inv := ValidInvoice; inv.Payment.Accounts[0].IBAN := 'DE02120300000000202052';
  Expect('BR-DE-19 IBAN-Prüfziffer', inv, 'BR-DE-19');
  inv := ValidInvoice; inv.Payment.Accounts := nil;
  Expect('BR-DE-23-a, BR-61 Überweisung ohne Konto', inv, 'BR-61 BR-DE-19 BR-DE-23-a');
  inv := ValidInvoice; inv.Seller.Contact.Email := 'erika@muster';
  Expect('BR-DE-28 E-Mail', inv, 'BR-DE-28');
  inv := ValidInvoice; inv.Seller.Contact := Default(TEInvoiceContact);
  Expect('BR-DE-2 Kontakt fehlt', inv, 'BR-DE-2');
  inv := ValidInvoice; inv.BuyerReference := '';
  Expect('BR-DE-15 Leitweg-ID', inv, 'BR-DE-15');
  inv := ValidInvoice; inv.Buyer.ElectronicAddress := Default(TEInvoiceID);
  Expect('R010 Käufer ohne elektronische Adresse', inv, 'PEPPOL-EN16931-R010');
  inv := ValidInvoice; inv.Lines[0].NetAmount := D('949.00'); inv.Totals.LineTotal := D('949.00');
  inv.Totals.TaxExclusive := D('949.00'); inv.Taxes[0].TaxableAmount := D('949.00');
  inv.Totals.TaxInclusive := D('1129.50'); inv.Totals.DuePayable := D('1129.50');
  Expect('R120 Menge x Preis (Warnung)', inv, 'PEPPOL-EN16931-R120');
  Check(TAbdecker.Check(inv, rep) and (rep.Warnings = 1), 'Warnung ändert das Ergebnis nicht');
  Check(rep.Messages[0].Origin = aboOfficial, 'R120 bei XRechnung 3.0: offizielle Regel');
  inv.Info.Profile := eiprofEN16931;
  inv.Specification := 'urn:cen.eu:en16931:2017';
  TAbdecker.Check(inv, rep);
  Check((Length(rep.Messages) = 1) and (rep.Messages[0].Code = 'PEPPOL-EN16931-R120') and
    (rep.Messages[0].Origin = aboExtra), 'R120 bei EN 16931: zusätzliche Prüfung', Codes(rep));
  inv := ValidInvoice; inv.Number := '';
  TAbdecker.Check(inv, rep);
  Check(rep.Messages[0].Origin = aboOfficial, 'BR-02: offizielle Regel');

  inv := ValidInvoice; inv.Lines[0].NetAmount := D('12,5');
  TAbdecker.Check(inv, rep);
  Check(Pos('invalid numbers', rep.NotChecked[0]) > 0, 'Ungültige Zahl: Rechnung übersprungen, ausgewiesen');

  inv := ValidInvoice; inv.Info.XRechnungVersion := '2.3';
  Expect('XRechnung 2.3: nur EN-Regeln', inv, '');
  TAbdecker.Check(inv, rep);
  Check((Length(rep.NotChecked) = 1) and (Pos('2.3', rep.NotChecked[0]) > 0), 'XRechnung 2.3 ausgewiesen');

  inv := ValidInvoice; inv.Info.Profile := eiprofMinimum; inv.Lines := nil;
  TAbdecker.Check(inv, rep);
  Check((rep.Errors = 0) and (Length(rep.RuleSets) = 0) and (Length(rep.NotChecked) = 1),
    'MINIMUM: keine Inhaltsregeln, aber ausgewiesen');
end;

{ ---- HTML ---- }

procedure TestStrip;
const
  // fx properties share the Description with pdfaid and others (as iText and
  // intarsys write it), one of them in attribute form; a namespace of the
  // ZUGFeRD community that must stay
  XMP_MIXED =
    '<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>'#10 +
    '<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'#10 +
    '<rdf:Description rdf:about="" xmlns:pdfaid="http://www.aiim.org/pdfa/ns/id/"'#10 +
    '    xmlns:fx="urn:factur-x:pdfa:CrossIndustryDocument:invoice:1p0#"'#10 +
    '    xmlns:adt="https://www.zugferd-community.net/additional-data/1.0#"'#10 +
    '    fx:DocumentType="INVOICE" pdfaid:conformance="B">'#10 +
    '  <pdfaid:part>3</pdfaid:part>'#10 +
    '  <fx:DocumentFileName>factur-x.xml</fx:DocumentFileName>'#10 +
    '  <fx:Version>1.0</fx:Version>'#10 +
    '  <fx:ConformanceLevel>EN 16931</fx:ConformanceLevel>'#10 +
    '  <adt:DocumentType>invoice</adt:DocumentType>'#10 +
    '</rdf:Description>'#10 +
    '</rdf:RDF></x:xmpmeta>'#10 +
    '<?xpacket end="w"?>';
  // fx declared on rdf:RDF: left in place with a warning
  XMP_ROOTDECL =
    '<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>'#10 +
    '<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"' +
    ' xmlns:fx="urn:factur-x:pdfa:CrossIndustryDocument:invoice:1p0#">'#10 +
    '<rdf:Description rdf:about="" xmlns:pdfaid="http://www.aiim.org/pdfa/ns/id/">' +
    '<pdfaid:part>3</pdfaid:part><fx:DocumentType>INVOICE</fx:DocumentType>' +
    '<fx:DocumentFileName>factur-x.xml</fx:DocumentFileName><fx:Version>1.0</fx:Version>' +
    '<fx:ConformanceLevel>EN 16931</fx:ConformanceLevel></rdf:Description>'#10 +
    '</rdf:RDF></x:xmpmeta>'#10 +
    '<?xpacket end="w"?>';
var
  pdf, xml, embedded, stripped, again, got: TBytes;
  msgs: TAbMessages;
  r: TAbResult;
  info: TEInvoiceInfo;
  name, xmlName, tail: string;
  stm, oth: Boolean;
begin
  Writeln('Entfernen');
  xml := U8(CIIFull);
  for stm := false to true do begin
    for oth := false to true do begin
      name := Format(' (Xref-Stream=%s, anderer Anhang=%s)', [BoolToStr(stm, true), BoolToStr(oth, true)]);
      pdf := BuildTestPdf(XMP_PDFA2, stm, oth);
      r := TAbdecker.EmbedBytes(pdf, xml, embedded, msgs);
      if r <> abOK then begin
        Check(false, 'Einbetten vor dem Entfernen' + name, MsgCodes(msgs));
        continue;
      end;
      r := TAbdecker.StripBytes(embedded, stripped, xmlName, msgs);
      Check(r = abOK, 'Entfernen' + name, TAbdecker.ResultText(r) + ' ' + MsgCodes(msgs));
      if r <> abOK then continue;
      Check(xmlName = 'xrechnung.xml', 'Name der entfernten Datei' + name, xmlName);
      Check(Length(msgs) = 0, 'Ohne Meldungen' + name, MsgCodes(msgs));
      Check(CompareMem(@stripped[0], @pdf[0], Length(pdf)), 'Ursprüngliches PDF unverändert vorne' + name);
      Check(not CompareMem(@stripped[0], @embedded[0], Length(embedded)), 'XML-Daten überschrieben' + name);
      Check((Pos('/Type /XRef', TEncoding.ANSI.GetString(Copy(stripped, Length(embedded), MaxInt))) > 0) = stm,
        'Xref-Form wie im Original' + name);
      r := TAbdecker.InfoFromBytes(stripped, info, msgs);
      Check(r = abNoInvoice, 'Keine Rechnung mehr' + name, TAbdecker.ResultText(r) + ' ' + MsgCodes(msgs));
      Check(info.XMPConformanceLevel = '', 'fx-Angaben aus dem XMP entfernt' + name, info.XMPConformanceLevel);
      Check((info.PDFAPart = '3') and Contains(stripped, 'Testdokument'), 'Übriges XMP bleibt' + name);
      Check(Contains(stripped, '/Lang (de-DE)') or Contains(stripped, '/Lang <64652d4445>'), 'Katalogeinträge bleiben' + name);
      if oth then begin
        Check((Length(info.Attachments) = 1) and (info.Attachments[0].Name = 'other.txt') and info.Attachments[0].InAF,
          'Anderer Anhang bleibt (mit /AF)' + name, IntToStr(Length(info.Attachments)));
        Check(Contains(stripped, '/Dests 6 0 R'), 'Sprungziele bleiben' + name);
      end else begin
        Check(Length(info.Attachments) = 0, 'Keine Anhänge mehr' + name, IntToStr(Length(info.Attachments)));
      end;
      // embed again, strip again
      r := TAbdecker.EmbedBytes(stripped, xml, again, msgs);
      Check((r = abOK) and (TAbdecker.ExtractXMLFromBytes(again, got, xmlName, msgs) = abOK) and
        (Length(got) = Length(xml)), 'Wieder einbetten' + name, MsgCodes(msgs));
      r := TAbdecker.StripBytes(again, stripped, xmlName, msgs);
      Check((r = abOK) and (TAbdecker.InfoFromBytes(stripped, info, msgs) = abNoInvoice),
        'Zweimal entfernen' + name, MsgCodes(msgs));
    end;
  end;

  // the XML data is gone from the file: uncompressed and compressed
  embedded := BuildPdf(xml, true, false, false);
  r := TAbdecker.StripBytes(embedded, stripped, xmlName, msgs);
  Check((r = abOK) and (BytesPos(embedded, xml) >= 0) and (BytesPos(stripped, xml) < 0) and
    (BytesPos(stripped, U8('Muster GmbH')) < 0) and (Length(msgs) = 0), 'Unkomprimierte XML-Daten überschrieben',
    MsgCodes(msgs));
  Check(TAbdecker.InfoFromBytes(stripped, info, msgs) = abNoInvoice, 'Nach dem Überschreiben lesbar', MsgCodes(msgs));

  // hand-made ZUGFeRD PDF: fx in attribute form, no other attachment
  embedded := BuildPdf(xml, true, true, false);
  r := TAbdecker.StripBytes(embedded, stripped, xmlName, msgs);
  Check((r = abOK) and (xmlName = 'factur-x.xml'), 'Entfernen (fx als Attribute)', MsgCodes(msgs));
  Check((BytesPos(embedded, Deflate(xml)) >= 0) and (BytesPos(stripped, Deflate(xml)) < 0),
    'Komprimierte XML-Daten überschrieben');
  r := TAbdecker.InfoFromBytes(stripped, info, msgs);
  Check((r = abNoInvoice) and (info.XMPConformanceLevel = '') and (info.PDFAPart = '3'),
    'fx-Attribute entfernt, pdfaid bleibt', info.XMPConformanceLevel + ' ' + info.PDFAPart);

  // fx mixed with other properties: only the fx properties go
  r := TAbdecker.EmbedBytes(BuildTestPdf(XMP_MIXED, false, false), xml, embedded, msgs);
  Check((r = abOK) and not HasMsg(msgs, 'EMBED-XMP'), 'Gemischtes XMP: eingebettet, XMP erhalten', MsgCodes(msgs));
  r := TAbdecker.StripBytes(embedded, stripped, xmlName, msgs);
  Check((r = abOK) and not HasMsg(msgs, 'STRIP-XMP'), 'Gemischtes XMP: entfernt', MsgCodes(msgs));
  r := TAbdecker.InfoFromBytes(stripped, info, msgs);
  Check((r = abNoInvoice) and (info.XMPConformanceLevel = '') and (info.XMPDocumentFileName = '') and
    (info.PDFAPart = '3') and (info.PDFAConformance = 'B'), 'Gemischtes XMP: fx weg, pdfaid bleibt',
    info.XMPConformanceLevel + '|' + info.XMPDocumentFileName + '|' + info.PDFAPart + info.PDFAConformance);
  // only the update counts: the earlier revisions still hold the old XMP
  tail := TEncoding.ANSI.GetString(Copy(stripped, Length(embedded), MaxInt));
  Check((Pos('<adt:DocumentType>invoice</adt:DocumentType>', tail) > 0) and (Pos('xmlns:adt=', tail) > 0) and
    (Pos('fx:', tail) = 0) and (Pos('xmlns:fx', tail) = 0) and
    (Pos('<pdfaid:part>3</pdfaid:part>'#10'  <adt:DocumentType>', tail) > 0),
    'Gemischtes XMP: andere Angaben und Zeilen bleiben', tail);
  r := TAbdecker.EmbedBytes(BuildTestPdf(XMP_ROOTDECL, false, false), xml, embedded, msgs);
  r := TAbdecker.StripBytes(embedded, stripped, xmlName, msgs);
  Check((r = abOK) and HasMsg(msgs, 'STRIP-XMP'), 'fx auf rdf:RDF deklariert: Warnung', MsgCodes(msgs));
  Check(TAbdecker.InfoFromBytes(stripped, info, msgs) = abNoInvoice, 'fx auf rdf:RDF deklariert: Rechnung entfernt');

  // signed (detected by /ByteRange): the bytes stay, the reference goes
  pdf := BuildTestPdf(StringReplace(XMP_PDFA2, 'Testdokument', 'Testdokument /ByteRange', []), false, false);
  r := TAbdecker.EmbedBytes(pdf, xml, embedded, msgs);
  r := TAbdecker.StripBytes(embedded, stripped, xmlName, msgs);
  Check((r = abOK) and HasMsg(msgs, 'STRIP-SIGNED') and CompareMem(@stripped[0], @embedded[0], Length(embedded)),
    'Signiertes PDF: Daten bleiben', MsgCodes(msgs));
  Check(TAbdecker.InfoFromBytes(stripped, info, msgs) = abNoInvoice, 'Signiertes PDF: Rechnung entfernt');

  // refusals
  r := TAbdecker.StripBytes(BuildTestPdf(XMP_PDFA2, false, true), stripped, xmlName, msgs);
  Check((r = abNoInvoice) and (Length(stripped) = 0), 'PDF ohne Rechnung', TAbdecker.ResultText(r));
  r := TAbdecker.StripBytes(xml, stripped, xmlName, msgs);
  Check((r = abUnsupported) and HasMsg(msgs, 'STRIP-NOT-PDF'), 'XML abgelehnt', MsgCodes(msgs));
  r := TAbdecker.StripBytes(BuildPdf(xml, true, false, true), stripped, xmlName, msgs);
  Check(r = abBrokenPDF, 'PDF mit kaputter Struktur abgelehnt', TAbdecker.ResultText(r) + ' ' + MsgCodes(msgs));
end;

function Doc(const FileName: string; const Content: string): TEInvoiceDocument;
begin
  result := Default(TEInvoiceDocument);
  result.FileName := FileName;
  result.Content := U8(Content);
end;

function OneDoc(const d: TEInvoiceDocument): TEInvoiceDocuments;
begin
  SetLength(result, 1);
  result[0] := d;
end;

procedure TestAttach;
var
  xml, outXml, twice: TBytes;
  docs: TEInvoiceDocuments;
  msgs: TAbMessages;
  r: TAbResult;
  inv, before: TEInvoice;
  rep, repBefore: TAbCheckReport;
  s: string;
  k: Integer;
begin
  Writeln('Anhänge');
  // CII: two files, one with description and special characters
  xml := U8(CIIFull);
  SetLength(docs, 2);
  docs[0] := Doc('Leistungsnachweis.pdf', '%PDF-1.4 test');
  docs[1] := Doc('Stunden & Kosten.csv', 'a;b'#10'1;2');
  docs[1].Description := 'Stunden <März>';
  TAbdecker.LoadFromBytes(xml, before, msgs);
  TAbdecker.Check(before, repBefore);
  r := TAbdecker.AttachBytes(xml, docs, outXml, msgs);
  Check(r = abOK, 'CII: zwei Anhänge', TAbdecker.ResultText(r) + ' ' + MsgCodes(msgs));
  if r = abOK then begin
    TAbdecker.LoadFromBytes(outXml, inv, msgs);
    Check(Length(inv.Documents) = Length(before.Documents) + 2, 'CII: Anhänge im Modell');
    if Length(inv.Documents) >= 2 then begin
      Check((inv.Documents[High(inv.Documents) - 1].MimeType = 'application/pdf') and
        (inv.Documents[High(inv.Documents) - 1].ID = 'Leistungsnachweis.pdf'), 'CII: MIME-Typ und ID aus dem Dateinamen');
      Check((inv.Documents[High(inv.Documents)].FileName = 'Stunden & Kosten.csv') and
        (inv.Documents[High(inv.Documents)].Description = 'Stunden <März>') and
        (TEncoding.UTF8.GetString(inv.Documents[High(inv.Documents)].Content) = 'a;b'#10'1;2'),
        'CII: Name, Beschreibung, Inhalt');
    end;
    TAbdecker.Check(inv, rep);
    Check(Codes(rep) = Codes(repBefore), 'CII: Prüfung unverändert', Codes(repBefore) + ' -> ' + Codes(rep));
    s := TEncoding.UTF8.GetString(outXml);
    Check(Pos('<ram:TypeCode>916</ram:TypeCode>', s) > 0, 'CII: TypeCode 916');
    // the comment of abdecker comes first (no declaration in this file)
    k := Pos(' -->', s) + 4;
    Check((Pos('<!-- abdecker ', s) = 1) and (Copy(s, k, Length(CIIFull) div 2) = Copy(CIIFull, 1, Length(CIIFull) div 2)),
      'CII: Anfang unverändert');
    // the same file again is refused
    r := TAbdecker.AttachBytes(outXml, OneDoc(docs[0]), twice, msgs);
    Check((r = abUnsupported) and HasMsg(msgs, 'ATTACH-EXISTS'), 'Doppelter Anhang abgelehnt', MsgCodes(msgs));
  end;

  // UBL: the documents go before AccountingSupplierParty
  r := TAbdecker.AttachBytes(U8(UBL), OneDoc(Doc('C:/tmp/sub\scan.png', 'PNG')), outXml, msgs);
  Check(r = abOK, 'UBL: Anhang', TAbdecker.ResultText(r) + ' ' + MsgCodes(msgs));
  if r = abOK then begin
    TAbdecker.LoadFromBytes(outXml, inv, msgs);
    Check((Length(inv.Documents) = 1) and (inv.Documents[0].MimeType = 'image/png') and
      (inv.Documents[0].FileName = 'scan.png'), 'UBL: Anhang im Modell');
    s := TEncoding.UTF8.GetString(outXml);
    Check((Pos('<cac:AdditionalDocumentReference>', s) > 0) and
      (Pos('<cac:AdditionalDocumentReference>', s) < Pos('<cac:AccountingSupplierParty>', s)) and
      (Pos('</cbc:DocumentCurrencyCode><cac:AdditionalDocumentReference>', s) > 0),
      'UBL: Position und Form (ohne Zeilenstruktur)');
  end;

  // refusals
  r := TAbdecker.AttachBytes(xml, OneDoc(Doc('notes.txt', 'x')), outXml, msgs);
  Check((r = abUnsupported) and HasMsg(msgs, 'ATTACH-TYPE'), 'Dateityp abgelehnt', MsgCodes(msgs));
  r := TAbdecker.AttachBytes(xml, OneDoc(Doc('leer.pdf', '')), outXml, msgs);
  Check((r = abUnsupported) and HasMsg(msgs, 'ATTACH-EMPTY'), 'Leere Datei abgelehnt', MsgCodes(msgs));
  r := TAbdecker.AttachBytes(U8(CII('urn:factur-x.eu:1p0:minimum', 'X')), OneDoc(Doc('a.pdf', 'x')), outXml, msgs);
  Check((r = abUnsupported) and HasMsg(msgs, 'ATTACH-PROFILE'), 'MINIMUM abgelehnt', MsgCodes(msgs));
  r := TAbdecker.AttachBytes(BuildPdf(xml, true, false, false), OneDoc(Doc('a.pdf', 'x')), outXml, msgs);
  Check((r = abUnsupported) and HasMsg(msgs, 'ATTACH-PDF'), 'PDF abgelehnt', MsgCodes(msgs));
  r := TAbdecker.AttachBytes(xml, nil, outXml, msgs);
  Check((r = abUnsupported) and HasMsg(msgs, 'ATTACH-NONE'), 'Ohne Dateien abgelehnt', MsgCodes(msgs));
end;

function CountOf(const Sub, s: string): Integer;
var
  p: Integer;
begin
  result := 0;
  p := Pos(Sub, s);
  while p > 0 do begin
    Inc(result);
    p := Pos(Sub, s, p + Length(Sub));
  end;
end;

procedure TestJson;
var
  msgs: TAbMessages;
  inv: TEInvoice;
  rep: TAbCheckReport;
  s: string;
begin
  Writeln('JSON');
  SetLength(msgs, 1);
  msgs[0].Severity := abWarning;
  msgs[0].Code := 'X-1';
  msgs[0].Text := 'a "b" \ c'#10'd'#9#1'ü';
  msgs[0].Origin := aboExtra;
  s := TAbdecker.MessagesToJson(abNoInvoice, msgs);
  Check(s = '{'#10'  "result": "no-invoice",'#10'  "messages": ['#10 +
    '    {"severity": "warning", "code": "X-1", "origin": "extra", "text": "a \"b\" \\ c\nd\t\u0001ü"}'#10 +
    '  ]'#10'}', 'Meldungen als JSON, Sonderzeichen maskiert', s);
  s := TAbdecker.MessagesToJson(abOK, nil);
  Check(s = '{'#10'  "result": "ok",'#10'  "messages": []'#10'}', 'Leere Meldungsliste', s);
  Check((TAbdecker.ResultCode(abBrokenPDF) = 'broken-pdf') and (TAbdecker.ProfileCode(eiprofXRechnung) = 'xrechnung') and
    (TAbdecker.SyntaxCode(eisynUBLCreditNote) = 'ubl-creditnote') and (TAbdecker.ContainerCode(eicontPDF) = 'pdf') and
    (TAbdecker.SeverityCode(abError) = 'error') and (TAbdecker.OriginCode(aboOfficial) = 'official'), 'Code-Wörter');

  inv := ValidInvoice;
  TAbdecker.Check(inv, rep);
  Check(not rep.Failed and not rep.Failed(abWarning) and not rep.Failed(abInfo), 'Failed: gültige Rechnung');
  s := TAbdecker.CheckToJson('x.xml', abOK, inv, rep);
  Check((Pos('"file": "x.xml",', s) > 0) and (Pos('"errors": 0,', s) > 0) and
    (Pos('"ruleSets": ["EN 16931", "XRechnung 3.0"],', s) > 0), 'Prüfbericht als JSON', s);
  inv.Lines[0].NetAmount := D('949.00'); inv.Totals.LineTotal := D('949.00');
  inv.Totals.TaxExclusive := D('949.00'); inv.Taxes[0].TaxableAmount := D('949.00');
  inv.Totals.TaxInclusive := D('1129.50'); inv.Totals.DuePayable := D('1129.50');
  TAbdecker.Check(inv, rep);
  Check(not rep.Failed and rep.Failed(abWarning) and rep.Failed(abInfo), 'Failed: nur Warnung');
  inv.Number := '';
  TAbdecker.Check(inv, rep);
  Check(rep.Failed and rep.Failed(abWarning), 'Failed: Fehler');
end;

function ReadFileBytes(const FileName: string): TBytes;
var
  fs: TFileStream;
begin
  fs := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(result, fs.Size);
    if Length(result) > 0 then begin
      fs.ReadBuffer(result[0], Length(result));
    end;
  finally
    fs.Free;
  end;
end;

procedure TestAttachments;
var
  xml, res: TBytes;
  docs: TEInvoiceDocuments;
  files: TEInvoiceFiles;
  msgs: TAbMessages;
  r: TAbResult;
  f, x, s: string;
begin
  Writeln('Anhänge auslesen');
  f := Root + 'testdata' + PathDelim + 'external' + PathDelim + 'corpus' + PathDelim + 'corpus-master' + PathDelim;
  x := f + 'XML-Rechnung' + PathDelim + 'CII' + PathDelim + 'XRECHNUNG_Einfach.cii.xml';
  if not FileExists(x) then begin
    Writeln('  übersprungen: Korpus fehlt');
    exit;
  end;
  xml := ReadFileBytes(x);
  r := TAbdecker.AttachmentsFromBytes(xml, files, msgs);
  Check((r = abOK) and (Length(files) = 0), 'XML ohne Anhänge', IntToStr(Length(files)));
  SetLength(docs, 2);
  docs[0] := Default(TEInvoiceDocument);
  docs[0].FileName := 'a.pdf';
  docs[0].Content := TEncoding.ASCII.GetBytes('%PDF-1.4 test');
  docs[1] := Default(TEInvoiceDocument);
  docs[1].FileName := 'b.csv';
  docs[1].Content := TEncoding.ASCII.GetBytes('x;y'#13#10'1;2');
  Check(TAbdecker.AttachBytes(xml, docs, res, msgs) = abOK, 'Anhängen für den Rundlauf');
  r := TAbdecker.AttachmentsFromBytes(res, files, msgs);
  Check((r = abOK) and (Length(files) = 2) and (files[0].Source = eisrcInvoice) and (files[0].Name = 'a.pdf') and
    (files[0].MimeType = 'application/pdf') and (TEncoding.ASCII.GetString(files[0].Content) = '%PDF-1.4 test') and
    (files[1].Name = 'b.csv') and (Length(files[1].Content) = 8), 'Rundlauf: angehängte Dateien kommen mit Inhalt zurück');

  r := TAbdecker.Attachments(f + 'XML-Rechnung' + PathDelim + 'FX' + PathDelim + 'EN16931_Einfach.pdf', files, msgs);
  Check((r = abOK) and (Length(files) = 1) and files[0].IsInvoice and (files[0].Source = eisrcPDF) and
    (files[0].Name = 'factur-x.xml') and (Length(files[0].Content) > 1000), 'PDF: die Rechnung als markierter Anhang');
  r := TAbdecker.Attachments(f + 'unstructured' + PathDelim + 'RE-E-974-Hetzner_2016-01-19_R0005532486.pdf', files, msgs);
  Check((r = abOK) and (Length(files) = 0), 'PDF ohne Rechnung: abOK, keine Anhänge');
  r := TAbdecker.AttachmentsFromBytes(TEncoding.ASCII.GetBytes('hello'), files, msgs);
  Check(r = abUnknownFormat, 'Weder PDF noch XML', TAbdecker.ResultText(r));
  s := TAbdecker.AttachmentsToJson('x', abOK, nil, nil, true);
  Check(Pos('"attachments": [],', s) > 0, 'Leere Anhangliste als JSON', s);
end;

{ Traces of abdecker: comment in changed XML, producer in changed PDF }
procedure TestMarks;
var
  xml, outXml, again, outPdf, stripped: TBytes;
  msgs: TAbMessages;
  r: TAbResult;
  s, mark, producer, f, xmlName: string;
begin
  Writeln('Spuren von abdecker');
  mark := '<!-- abdecker ' + AbdeckerVersion + ' by ' + AbdeckerAuthor;
  // XML: after the declaration, line breaks as in the file, replaced on the next change
  xml := U8(CII('urn:cen.eu:en16931:2017', 'X'));
  r := TAbdecker.AttachBytes(xml, OneDoc(Doc('a.pdf', 'x')), outXml, msgs);
  s := TEncoding.UTF8.GetString(outXml);
  Check((r = abOK) and (Pos('?>'#10 + mark + #10'     ' + AbdeckerRepo + #10'     ' + AbdeckerHome + ' -->'#10 +
    '<!-- Testrechnung -->', s) > 0), 'XML: Kommentar nach der Deklaration', MsgCodes(msgs));
  r := TAbdecker.AttachBytes(outXml, OneDoc(Doc('b.pdf', 'y')), again, msgs);
  Check((r = abOK) and (CountOf('<!-- abdecker ', TEncoding.UTF8.GetString(again)) = 1),
    'XML: Kommentar wird ersetzt, nicht verdoppelt');
  xml := U8(StringReplace(CII('urn:cen.eu:en16931:2017', 'X'), #10, #13#10, [rfReplaceAll]));
  r := TAbdecker.AttachBytes(xml, OneDoc(Doc('a.pdf', 'x')), outXml, msgs);
  Check((r = abOK) and (Pos('?>'#13#10 + mark + #13#10'     ', TEncoding.UTF8.GetString(outXml)) > 0),
    'XML: Zeilenende CRLF wie in der Datei');
  r := TAbdecker.AttachBytes(U8(UBL), OneDoc(Doc('a.pdf', 'x')), outXml, msgs);
  Check((r = abOK) and (Pos(mark + ', ' + AbdeckerRepo + ', ' + AbdeckerHome + ' --><Invoice ',
    TEncoding.UTF8.GetString(outXml)) = 1), 'XML: einzeilig, ohne Deklaration vorne');

  // PDF: producer in the Info dictionary and in the XMP
  producer := 'abdecker ' + AbdeckerVersion + ' (' + AbdeckerHome + ')';
  r := TAbdecker.EmbedBytes(BuildTestPdf(XMP_PDFA2, false, false), U8(CIIFull), outPdf, msgs);
  Check((r = abOK) and Contains(outPdf, '/Producer (abdecker ' + AbdeckerVersion + ' \(' + AbdeckerHome + '\))') and
    Contains(outPdf, '<pdf:Producer>' + producer + '</pdf:Producer>'), 'PDF: Producer in Info und XMP', MsgCodes(msgs));
  r := TAbdecker.StripBytes(outPdf, stripped, xmlName, msgs);
  s := TEncoding.ANSI.GetString(Copy(stripped, Length(outPdf), MaxInt));
  Check((r = abOK) and (Pos('/Producer (abdecker ', s) > 0) and (Pos('; abdecker', s) = 0) and
    (Pos('<pdf:Producer>' + producer + '</pdf:Producer>', s) > 0), 'PDF: eigener Producer ersetzt, nicht verdoppelt',
    MsgCodes(msgs));
  f := Root + 'testdata' + PathDelim + 'external' + PathDelim + 'corpus' + PathDelim + 'corpus-master' + PathDelim +
    'XML-Rechnung' + PathDelim + 'FX' + PathDelim + 'EN16931_Einfach.pdf';
  if FileExists(f) then begin
    r := TAbdecker.StripBytes(ReadFileBytes(f), stripped, xmlName, msgs);
    Check((r = abOK) and Contains(stripped, '; abdecker ' + AbdeckerVersion + ' \('),
      'PDF: an den vorhandenen Producer angehängt', MsgCodes(msgs));
  end;
end;

procedure TestHtml;
var
  inv: TEInvoice;
  h: string;
begin
  Writeln('HTML');
  inv := ValidInvoice;
  inv.Seller.Name := '<script>alert("x")</script> & Söhne';
  inv.Lines[0].ItemDescription := 'Zeile 1'#10'<img src=x onerror=alert(1)>';
  SetLength(inv.Documents, 2);
  inv.Documents[0].ID := 'A1';
  inv.Documents[0].FileName := 'stunden.csv';
  inv.Documents[0].MimeType := 'text/csv';
  inv.Documents[0].Content := U8('a;b'#10'1;2');
  inv.Documents[1].ID := 'A2';
  inv.Documents[1].FileName := 'boese.html';
  inv.Documents[1].MimeType := 'text/html';
  inv.Documents[1].Content := U8('<script>alert(1)</script>');
  inv.Documents[1].URI := 'javascript:alert(1)';
  h := TAbdecker.ToHtml(inv);
  Check(Pos('<!DOCTYPE html>', h) = 1, 'HTML beginnt mit DOCTYPE');
  Check(Pos('Content-Security-Policy', h) > 0, 'CSP gesetzt');
  Check(Pos('<script', h) = 0, 'Kein Skript-Tag, auch nicht aus Daten');
  Check(Pos('&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp; Söhne', h) > 0, 'Verkäufername escaped');
  Check(Pos('&lt;img src=x onerror=alert(1)&gt;', h) > 0, 'Beschreibung escaped');
  Check(Pos('Zeile 1<br>', h) > 0, 'Zeilenumbruch erhalten');
  Check(Pos('href="data:text/csv;base64,YTtiCjE7Mg=="', h) > 0, 'Anhang als Data-URI');
  Check(Pos('data:text/html', h) = 0, 'Gefährlicher MIME-Typ nicht übernommen');
  Check(Pos('data:application/octet-stream;base64,', h) > 0, 'Unbekannter Typ als Download');
  Check(Pos('href="javascript:', h) = 0, 'Kein javascript:-Link');
  Check(Pos('1.130,50 EUR', h) > 0, 'Betrag deutsch formatiert');
  Check(Pos('01.03.2024', h) > 0, 'Datum deutsch');
  Check((Pos('Prüfung: 1 Fehler', h) > 0) and (Pos('BR-CL-24', h) > 0), 'Prüfergebnis enthalten (MIME-Typ text/html ist unzulässig)');
  Check(CountOf('<table', h) = CountOf('</table>', h), 'Tabellen geschlossen');
  Check(CountOf('<div', h) = CountOf('</div>', h), 'Divs geschlossen');
  Check((Pos('<meta name="generator" content="abdecker ' + AbdeckerVersion + '">', h) > 0) and
    (Pos('<a href="' + AbdeckerRepo + '">', h) > 0) and (Pos('<a href="' + AbdeckerHome + '">', h) > 0),
    'Generator und Links auf abdecker');
  h := TAbdecker.ToHtml(inv, 'en', false);
  Check((Pos('1,130.50 EUR', h) > 0) and (Pos('2024-03-01', h) > 0) and (Pos('Amount due', h) > 0),
    'Englisch: Betrag, Datum, Beschriftung');
  Check(Pos('No errors found', h) = 0, 'Ohne Prüfung kein Prüfergebnis');
end;

{ ---- payment and GiroCode ---- }

{ s n times (StringOfChar takes a Char, under FPC 'ä' is two bytes) }
function Repeated(const s: string; n: Integer): string;
var
  i: Integer;
begin
  result := '';
  for i := 1 to n do result := result + s;
end;

procedure TestPayment;
const
  Head = 'BCD'#10'002'#10'1'#10'SCT'#10;
var
  inv, v: TEInvoice;
  h, svg: string;
  qr: TQrCode;
begin
  Writeln('Zahlung und GiroCode');
  inv := ValidInvoice;
  Check(TAbdecker.GiroCode(inv) = Head + #10'Muster GmbH'#10'DE02120300000000202051'#10'EUR1130.50'#10#10#10'R-1',
    'GiroCode: ohne BIC, Rechnungsnummer als Verwendungszweck', TAbdecker.GiroCode(inv));
  h := TAbdecker.ToHtml(inv);
  Check((Pos('<div class="pay">', h) > 0) and (Pos('<svg', h) > 0) and (Pos('Mit der Banking-App scannen', h) > 0),
    'HTML: Überweisungsträger mit QR-Code');
  Check(Pos('<span class="sel iban"><span>DE02</span><span>1203</span>', h) > 0, 'HTML: IBAN in Vierergruppen');
  Check(Pos('<span class="sel">1130,50</span> EUR', h) > 0, 'HTML: Betrag zum Kopieren ohne Tausenderpunkt');
  Check(Pos('<script', h) = 0, 'HTML: weiterhin kein Skript');
  Check(Pos('<span class="sel">R-1</span> <span class="small">(Rechnungsnummer)</span>', h) > 0,
    'HTML: Verwendungszweck aus der Rechnungsnummer gekennzeichnet');

  v := ValidInvoice;   // a fresh copy: dynamic arrays are shared on assignment
  v.Payment.Accounts[0].IBAN := 'de02 1203 0000 0000 2020 51';
  v.Payment.Accounts[0].BIC := 'BYLADEM1001';
  v.Payment.Accounts[0].Name := 'Muster GmbH'#10'Konto 2';
  v.Payment.RemittanceInfo := 'Rechnung R-1'#10'Kunde 4711';
  Check(TAbdecker.GiroCode(v) = Head + 'BYLADEM1001'#10'Muster GmbH Konto 2'#10'DE02120300000000202051'#10'EUR1130.50'#10#10#10 +
    'Rechnung R-1 Kunde 4711', 'GiroCode: BIC, Kontoinhaber, IBAN ohne Leerzeichen, Zeilenumbrüche zu Leerzeichen',
    TAbdecker.GiroCode(v));
  v.Payment.RemittanceInfo := 'RF18 5390 0754 7034';
  Check(TAbdecker.GiroCode(v) = Head + 'BYLADEM1001'#10'Muster GmbH Konto 2'#10'DE02120300000000202051'#10'EUR1130.50'#10#10 +
    'RF18539007547034', 'GiroCode: Gläubigerreferenz (RF) im strukturierten Feld', TAbdecker.GiroCode(v));
  v.Payment.RemittanceInfo := 'RF19 5390 0754 7034';
  Check(Pos(#10#10#10'RF19 5390 0754 7034', TAbdecker.GiroCode(v)) > 0, 'GiroCode: falsche Prüfziffer bleibt Freitext');
  v.Payment.Accounts[0].Name := Repeated('ä', 75);
  Check(Pos(#10 + Repeated('ä', 70) + #10, TAbdecker.GiroCode(v)) > 0, 'GiroCode: Empfänger auf 70 Zeichen gekürzt');

  v := ValidInvoice;
  v.Totals.DuePayable := D('1130.5');
  Check(Pos(#10'EUR1130.50', TAbdecker.GiroCode(v)) > 0, 'GiroCode: Betrag mit zwei Nachkommastellen');
  v.Totals.DuePayable := D('1130.505');
  h := TAbdecker.ToHtml(v);
  Check((TAbdecker.GiroCode(v) = '') and (Pos('Der Zahlbetrag fehlt oder ist unbrauchbar', h) > 0),
    'Betrag mit drei Nachkommastellen: kein Code, Hinweis');

  v := ValidInvoice;
  v.Currency := 'USD';
  h := TAbdecker.ToHtml(v);
  Check((TAbdecker.GiroCode(v) = '') and (Pos('nur für Euro', h) > 0) and (Pos('<svg', h) = 0),
    'Fremdwährung: kein Code, Hinweis');

  v := ValidInvoice;
  v.Payment.Accounts[0].IBAN := 'DE02120300000000202052';
  h := TAbdecker.ToHtml(v);
  Check((TAbdecker.GiroCode(v) = '') and (Pos('IBAN ungültig', h) > 0) and (Pos('<svg', h) = 0),
    'Ungültige IBAN: kein Code, deutliche Warnung');
  v.Payment.Accounts[0].IBAN := '52491234';
  h := TAbdecker.ToHtml(v);
  Check((TAbdecker.GiroCode(v) = '') and (Pos('IBAN ungültig', h) = 0) and (Pos('Das Konto ist keine IBAN', h) > 0) and
    (Pos('<td>Konto</td><td><span class="sel">52491234</span>', h) > 0), 'Kontonummer ohne IBAN: kein Code, keine Warnung');

  v := ValidInvoice;
  v.Payment.Accounts := nil;
  h := TAbdecker.ToHtml(v);
  Check((TAbdecker.GiroCode(v) = '') and (Pos('nennt kein Konto', h) > 0), 'SEPA-Überweisung ohne Konto: Hinweis');

  v := ValidInvoice;
  SetLength(v.Payment.Accounts, 2);
  v.Payment.Accounts[1].IBAN := 'DE89370400440532013000';
  h := TAbdecker.ToHtml(v);
  Check((Pos(#10'DE02120300000000202051'#10, TAbdecker.GiroCode(v)) > 0) and (Pos('Weiteres Konto', h) > 0) and
    (Pos('DE89370400440532013000', h) > 0), 'Mehrere Konten: das erste im Code, die anderen gezeigt');

  v := ValidInvoice;
  v.Payment.MeansCode := '59';
  v.Payment.MandateID := 'M-1';
  h := TAbdecker.ToHtml(v);
  Check((TAbdecker.GiroCode(v) = '') and (Pos('Wird per Lastschrift eingezogen: <b>1.130,50 EUR</b>', h) > 0) and
    (Pos('M-1', h) > 0), 'Lastschrift: kein Code, Hinweis und Mandat');

  v := ValidInvoice;
  v.Totals.DuePayable := D('0.00');
  h := TAbdecker.ToHtml(v);
  Check((TAbdecker.GiroCode(v) = '') and (Pos('Nichts zu zahlen', h) > 0), 'Zahlbetrag 0: nichts zu zahlen');

  v := ValidInvoice;
  v.TypeCode := '381';
  h := TAbdecker.ToHtml(v);
  Check((TAbdecker.GiroCode(v) = '') and (Pos('Gutschrift zugunsten des Käufers', h) > 0) and (Pos('<svg', h) = 0),
    'Gutschrift: kein Code');

  v := ValidInvoice;
  v.PaymentTerms := '2 % Skonto bei Zahlung in 10 Tagen'#10'#SKONTO#TAGE=10#PROZENT=2.00#'#10 +
    '#SKONTO#TAGE=20#PROZENT=1.00#BASISBETRAG=1000.00#'#10;
  h := TAbdecker.ToHtml(v);
  // 1130.50 - 22.61 = 1107.89; 1130.50 - 10.00 = 1120.50; invoice date 2024-03-01
  Check((Pos('2 % bis 11.03.2024 (10 Tage): <span class="sel">1107,89</span> EUR', h) > 0) and
    (Pos('1 % bis 21.03.2024 (20 Tage): <span class="sel">1120,50</span> EUR', h) > 0),
    'Skonto: Betrag und Frist (vom Zahlbetrag bzw. Basisbetrag, ab Rechnungsdatum)');
  Check(CountOf('<svg', h) = 3, 'Skonto: ein Code je Betrag', IntToStr(CountOf('<svg', h)));

  h := TAbdecker.ToHtml(inv, 'de', true, true);
  Check((Pos('<title>Zahlung: Rechnung R-1</title>', h) > 0) and (Pos('<div class="pay">', h) > 0) and
    (Pos('Positionen', h) = 0) and (Pos('Prüfung:', h) > 0) and (Pos('</html>', h) > 0),
    'Nur Zahlung: Überweisungsträger und Prüfergebnis, keine Positionen');
  h := TAbdecker.ToHtml(inv, 'en', false, true);
  Check((Pos('Scan with your banking app', h) > 0) and (Pos('<span class="sel">1130.50</span> EUR', h) > 0),
    'Nur Zahlung, englisch');

  // QR code itself (compared module by module with segno: tests/qr.py)
  svg := TAbdecker.QrCodeSvg('abdecker');
  Check((Pos('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 29 29"', svg) = 1) and (Pos('</svg>', svg) > 0),
    'QR als SVG: Version 1 (21 Module) plus Ruhezone');
  Check(TAbdecker.QrCodeSvg(StringOfChar('x', 2331)) <> '', 'QR: 2331 Bytes passen (Version 40)');
  Check(TAbdecker.QrCodeSvg(StringOfChar('x', 2332)) = '', 'QR: 2332 Bytes zu lang');
  Check(QrEncode(U8('abdecker'), qr) and (qr.Version = 1) and (qr.Size = 21) and qr.Dark(0, 0) and
    not qr.Dark(7, 0) and qr.Dark(8, 13), 'QR: Suchmuster, Trennlinie, dunkles Modul');
end;

{ ---- model dump (abdecker.util) ---- }

procedure DumpInvoice(const Inv: TEInvoice; Norm, WithUnmapped: Boolean; l: TStrings);
begin
  DumpModel(Inv, Norm, WithUnmapped, l);
end;

{ ---- corpus run ---- }

procedure ListFiles(const Dir: string; List: TStrings);
var
  sr: TSearchRec;
  ext: string;
begin
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile, sr) = 0 then begin
    try
      repeat
        if (sr.Name = '.') or (sr.Name = '..') then continue;
        if (sr.Attr and faDirectory) <> 0 then begin
          ListFiles(IncludeTrailingPathDelimiter(Dir) + sr.Name, List);
        end else begin
          ext := LowerCase(ExtractFileExt(sr.Name));
          if (ext = '.pdf') or (ext = '.xml') then begin
            List.Add(IncludeTrailingPathDelimiter(Dir) + sr.Name);
          end;
        end;
      until FindNext(sr) <> 0;
    finally
      FindClose(sr);
    end;
  end;
end;

const
  GuidelineEN = '<ram:ID>urn:cen.eu:en16931:2017</ram:ID>';
  GuidelineXR = '<ram:ID>urn:cen.eu:en16931:2017#compliant#urn:xeinkauf.de:kosit:xrechnung_3.0</ram:ID>';

{ Templates: every templates/<name>.json has the expected CII in
  tests/templates/<name>.xml (written by hand, later the reference for the
  writer). Each XML passes the check without any message under its own
  profile and, except minimal, also under the other one: the templates are
  strict, they meet XRechnung 3.0 even as EN 16931. }
procedure TestTemplates;
var
  files: TStringList;
  sr: TSearchRec;
  i: Integer;
  name, xml, other: string;
  inv: TEInvoice;
  rep: TAbCheckReport;
  r: TAbResult;
begin
  Writeln('Vorlagen');
  files := TStringList.Create;
  try
    ListFiles(Root + 'tests' + PathDelim + 'templates', files);
    files.Sort;
    Check(files.Count >= 6, 'Vorlagen vorhanden', IntToStr(files.Count));

    for i := 0 to files.Count - 1 do begin
      name := ChangeFileExt(ExtractFileName(files[i]), '');
      Check(FileExists(Root + 'templates' + PathDelim + name + '.json'), name + ': JSON-Vorlage vorhanden');
      r := TAbdecker.CheckFile(files[i], inv, rep);
      Check((r = abOK) and (Length(rep.Messages) = 0), name + ': fehlerfrei', MsgCodes(rep.Messages));
      if name = 'minimal' then continue;

      xml := TEncoding.UTF8.GetString(ReadFileBytes(files[i]));
      if Pos(GuidelineXR, xml) > 0 then begin
        other := StringReplace(xml, GuidelineXR, GuidelineEN, []);
      end else begin
        other := StringReplace(xml, GuidelineEN, GuidelineXR, []);
      end;

      r := TAbdecker.CheckBytes(U8(other), inv, rep);
      Check((other <> xml) and (r = abOK) and (Length(rep.Messages) = 0), name + ': fehlerfrei auch im anderen Profil',
        MsgCodes(rep.Messages));
    end;

    if FindFirst(Root + 'templates' + PathDelim + '*.json', faAnyFile, sr) = 0 then begin
      try
        repeat
          name := ChangeFileExt(sr.Name, '');
          Check(files.IndexOf(Root + 'tests' + PathDelim + 'templates' + PathDelim + name + '.xml') >= 0,
            name + ': erwartetes XML vorhanden');
        until FindNext(sr) <> 0;
      finally
        FindClose(sr);
      end;
    end;
  finally
    files.Free;
  end;
end;

procedure RunCorpus(Update: Boolean);
var
  files, actual, expected, stats: TStringList;
  dir, rel, lineStr, goldenFile: string;
  i, diffs: Integer;
  info: TEInvoiceInfo;
  msgs: TAbMessages;
  r: TAbResult;
  counts: array[TAbResult] of Integer;
  rr: TAbResult;
  sw: TStopwatch;
begin
  Writeln('Korpus');
  dir := Root + 'testdata' + PathDelim + 'external';
  if not DirectoryExists(dir) then begin
    Writeln('  übersprungen: ', dir, ' fehlt (tools/fetch-testdata.sh)');
    exit;
  end;
  files := TStringList.Create;
  actual := TStringList.Create;
  expected := TStringList.Create;
  stats := TStringList.Create;
  try
    ListFiles(dir, files);
    files.CaseSensitive := true;
    files.Sort;
    FillChar(counts, SizeOf(counts), 0);
    sw := TStopwatch.StartNew;
    for i := 0 to files.Count - 1 do begin
      rel := StringReplace(Copy(files[i], Length(dir) + 2, MaxInt), '\', '/', [rfReplaceAll]);
      r := TAbdecker.Info(files[i], info, msgs);
      Inc(counts[r]);
      lineStr := rel + #9 + ResultNames[r] + #9 + ContainerNames[info.Container] + #9 +
        SyntaxNames[info.Syntax] + #9 + ProfileNames[info.Profile] + #9 + info.XRechnungVersion + #9 +
        info.InvoiceFileName + #9 + MsgCodes(msgs);
      actual.Add(lineStr);
      Check(r <> abInternalError, 'Kein interner Fehler: ' + rel, MsgCodes(msgs));
    end;
    sw.Stop;
    Writeln(Format('  %d Dateien in %d ms', [files.Count, sw.ElapsedMilliseconds]));
    for rr := Low(TAbResult) to High(TAbResult) do begin
      if counts[rr] > 0 then begin
        Writeln(Format('  %-14s %4d', [ResultNames[rr], counts[rr]]));
      end;
    end;

    actual.LineBreak := #10;
    actual.WriteBOM := false;
    goldenFile := Root + 'tests' + PathDelim + 'golden' + PathDelim + 'corpus.txt';
    ForceDirectories(ExtractFilePath(goldenFile));
    actual.SaveToFile(ChangeFileExt(goldenFile, '.actual.txt'), TEncoding.UTF8);
    if Update or not FileExists(goldenFile) then begin
      actual.SaveToFile(goldenFile, TEncoding.UTF8);
      Writeln('  Referenz geschrieben: ', goldenFile);
      exit;
    end;
    expected.LoadFromFile(goldenFile, TEncoding.UTF8);
    diffs := 0;
    for i := 0 to actual.Count - 1 do begin
      if expected.IndexOf(actual[i]) < 0 then begin
        Inc(diffs);
        if diffs <= 20 then begin
          Writeln('  + ', actual[i]);
        end;
      end;
    end;
    for i := 0 to expected.Count - 1 do begin
      if actual.IndexOf(expected[i]) < 0 then begin
        Inc(diffs);
        if diffs <= 20 then begin
          Writeln('  - ', expected[i]);
        end;
      end;
    end;
    Check(diffs = 0, 'Korpus entspricht Referenz', IntToStr(diffs) + ' Abweichungen (abdeckertests --update übernimmt)');
  finally
    stats.Free;
    expected.Free;
    actual.Free;
    files.Free;
  end;
end;

{ Every PDF invoice of the corpus is stripped, every invoice XML gets an
  attachment: no internal errors, results readable, check findings unchanged }
procedure RunEditCorpus;
var
  noBG24: Boolean;
  files: TStringList;
  dir, rel, xmlName, before: string;
  i, nStrip, nStripNo, nAttach, nAttachNo, nKept, nEmbed: Integer;
  data, xml, outData, back: TBytes;
  info, info2: TEInvoiceInfo;
  inv: TEInvoice;
  msgs, m2: TAbMessages;
  r: TAbResult;
  rep: TAbCheckReport;
begin
  Writeln('Entfernen, Anhängen, UBL einbetten (Korpus)');
  dir := Root + 'testdata' + PathDelim + 'external';
  if not DirectoryExists(dir) then exit;
  files := TStringList.Create;
  try
    ListFiles(dir, files);
    files.Sort;
    nStrip := 0;
    nStripNo := 0;
    nAttach := 0;
    nAttachNo := 0;
    nKept := 0;
    nEmbed := 0;
    for i := 0 to files.Count - 1 do begin
      rel := StringReplace(Copy(files[i], Length(dir) + 2, MaxInt), '\', '/', [rfReplaceAll]);
      data := ReadFileBytes(files[i]);
      TAbdecker.InfoFromBytes(data, info, msgs);
      xml := nil;
      if (info.Container = eicontPDF) and (info.InvoiceFileName <> '') then begin
        r := TAbdecker.StripBytes(data, outData, xmlName, msgs);
        Check(r <> abInternalError, 'Entfernen ohne internen Fehler: ' + rel, MsgCodes(msgs));
        if r = abOK then begin
          Inc(nStrip);
          if HasMsg(msgs, 'STRIP-SIGNED') or HasMsg(msgs, 'STRIP-REFERENCED') then begin
            Inc(nKept);
            Writeln('  XML-Daten bleiben: ', rel, ' ', MsgCodes(msgs));
          end;
          r := TAbdecker.InfoFromBytes(outData, info2, m2);
          Check((r = abNoInvoice) or HasMsg(msgs, 'STRIP-ANOTHER'), 'Nach dem Entfernen keine Rechnung: ' + rel,
            TAbdecker.ResultText(r));
          Check((info2.XMPConformanceLevel = '') or HasMsg(msgs, 'STRIP-XMP'), 'fx-Angaben entfernt: ' + rel,
            info2.XMPConformanceLevel);
        end else begin
          Inc(nStripNo);
          Writeln('  nicht entfernt: ', rel, ' ', MsgCodes(msgs));
        end;
        TAbdecker.ExtractXMLFromBytes(data, xml, xmlName, msgs);
      end else if info.Container = eicontXML then xml := data;
      if (Length(xml) = 0) or (TAbdecker.LoadFromBytes(xml, inv, msgs) <> abOK) then continue;
      // UBL: embedded as CII (converted)
      if inv.Info.Syntax in [eisynUBLInvoice, eisynUBLCreditNote] then begin
        r := TAbdecker.EmbedBytes(BuildTestPdf('', false, false), xml, outData, msgs);
        Check(r = abOK, 'UBL eingebettet: ' + rel, MsgCodes(msgs));
        if r = abOK then begin
          Inc(nEmbed);
          TAbdecker.ExtractXMLFromBytes(outData, back, xmlName, m2);
          TAbdecker.InfoFromBytes(back, info2, m2);
          Check(info2.Syntax = eisynCII, 'UBL eingebettet als CII: ' + rel, TAbdecker.SyntaxCode(info2.Syntax));
        end;
      end;
      noBG24 := not ((inv.Info.Syntax in [eisynUBLInvoice, eisynUBLCreditNote]) or ((inv.Info.Syntax = eisynCII) and
        not (inv.Info.Profile in [eiprofMinimum, eiprofBasicWL, eiprofBasic])));
      if noBG24 then continue;
      TAbdecker.Check(inv, rep);
      before := Codes(rep);
      r := TAbdecker.AttachBytes(xml, OneDoc(Doc('abdecker-test.pdf', '%PDF-1.4')), outData, msgs);
      Check(r <> abInternalError, 'Anhängen ohne internen Fehler: ' + rel, MsgCodes(msgs));
      if r = abOK then begin
        Inc(nAttach);
        TAbdecker.LoadFromBytes(outData, inv, msgs);
        TAbdecker.Check(inv, rep);
        Check(Codes(rep) = before, 'Prüfung nach dem Anhängen unverändert: ' + rel, before + '-> ' + Codes(rep));
      end else begin
        Inc(nAttachNo);
        Writeln('  nicht angehängt: ', rel, ' ', MsgCodes(msgs));
      end;
    end;
    Writeln(Format('  %d PDFs ohne Rechnung (Daten überschrieben: %d), %d abgelehnt; %d XML mit Anhang, %d abgelehnt;' +
      ' %d UBL eingebettet', [nStrip, nStrip - nKept, nStripNo, nAttach, nAttachNo, nEmbed]));
  finally
    files.Free;
  end;
end;

function GoldenPath(const Name: string): string;
begin
  result := Root + 'tests' + PathDelim + 'golden' + PathDelim + Name;
end;

procedure SaveLines(l: TStringList; const FileName: string);
begin
  l.LineBreak := #10;
  l.WriteBOM := false;
  ForceDirectories(ExtractFilePath(FileName));
  l.SaveToFile(FileName, TEncoding.UTF8);
end;

{ Splits '== name' sections into names and bodies }
procedure SplitSections(l: TStringList; Names, Bodies: TStringList);
var
  i: Integer;
  sb: TStringBuilder;
begin
  sb := TStringBuilder.Create;
  try
    for i := 0 to l.Count - 1 do begin
      if Copy(l[i], 1, 3) = '== ' then begin
        if Names.Count > 0 then begin
          Bodies.Add(sb.ToString);
        end;
        sb.Clear;
        Names.Add(Copy(l[i], 4, MaxInt));
      end else begin
        sb.Append(l[i]).Append(#10);
      end;
    end;
    if Names.Count > 0 then begin
      Bodies.Add(sb.ToString);
    end;
  finally
    sb.Free;
  end;
end;

function FirstDiff(const a, b: string): string;
var
  la, lb: TStringList;
  i: Integer;
begin
  la := TStringList.Create;
  lb := TStringList.Create;
  try
    la.Text := a;
    lb.Text := b;
    for i := 0 to la.Count - 1 do begin
      if (i >= lb.Count) or (la[i] <> lb[i]) then begin
        result := 'ist: ' + la[i];
        if i < lb.Count then result := result + ' | war: ' + lb[i];
        exit;
      end;
    end;
    if lb.Count > la.Count then begin
      result := 'fehlt: ' + lb[la.Count];
    end else begin
      result := '';
    end;
  finally
    lb.Free;
    la.Free;
  end;
end;

{ Compares a sectioned golden file; reports changed, new and missing sections }
procedure CompareSections(const Name: string; Actual: TStringList; Update: Boolean);
var
  expected, an, ab, en, eb: TStringList;
  i, j, diffs: Integer;
begin
  SaveLines(Actual, ChangeFileExt(GoldenPath(Name), '.actual.txt'));
  if Update or not FileExists(GoldenPath(Name)) then begin
    SaveLines(Actual, GoldenPath(Name));
    Writeln('  Referenz geschrieben: ', Name);
    exit;
  end;
  expected := TStringList.Create;
  an := TStringList.Create;
  ab := TStringList.Create;
  en := TStringList.Create;
  eb := TStringList.Create;
  try
    expected.LoadFromFile(GoldenPath(Name), TEncoding.UTF8);
    SplitSections(Actual, an, ab);
    SplitSections(expected, en, eb);
    diffs := 0;
    for i := 0 to an.Count - 1 do begin
      j := en.IndexOf(an[i]);
      if (j < 0) or (ab[i] <> eb[j]) then begin
        Inc(diffs);
        if diffs <= 20 then begin
          if j < 0 then begin
            Writeln('  neu: ', an[i]);
          end else begin
            Writeln('  geändert: ', an[i], #10'    ', FirstDiff(ab[i], eb[j]));
          end;
        end;
      end;
    end;
    for i := 0 to en.Count - 1 do begin
      if an.IndexOf(en[i]) < 0 then begin
        Inc(diffs);
        if diffs <= 20 then begin
          Writeln('  fehlt: ', en[i]);
        end;
      end;
    end;
    Check(diffs = 0, Name + ' entspricht Referenz', IntToStr(diffs) + ' Abweichungen (abdeckertests --update übernimmt)');
  finally
    eb.Free;
    en.Free;
    ab.Free;
    an.Free;
    expected.Free;
  end;
end;

procedure RunModel(Update: Boolean);
var
  files, model, stats, pairs, dump, a, b: TStringList;
  dir, rel, path, key, partner: string;
  i, j, k, loaded, pairCount, pairDiffs: Integer;
  inv, big: TEInvoice;
  msgs: TAbMessages;
  r: TAbResult;
  sw: TStopwatch;
begin
  Writeln('Modell (Korpus)');
  dir := Root + 'testdata' + PathDelim + 'external';
  if not DirectoryExists(dir) then begin
    Writeln('  übersprungen: ', dir, ' fehlt');
    exit;
  end;
  files := TStringList.Create;
  model := TStringList.Create;
  stats := TStringList.Create;
  pairs := TStringList.Create;
  dump := TStringList.Create;
  a := TStringList.Create;
  b := TStringList.Create;
  try
    ListFiles(dir, files);
    files.CaseSensitive := true;
    files.Sort;
    stats.Sorted := true;
    stats.Duplicates := dupIgnore;
    loaded := 0;
    sw := TStopwatch.StartNew;
    for i := 0 to files.Count - 1 do begin
      rel := StringReplace(Copy(files[i], Length(dir) + 2, MaxInt), '\', '/', [rfReplaceAll]);
      r := TAbdecker.Load(files[i], inv, msgs);
      Check(r <> abInternalError, 'Modell ohne internen Fehler: ' + rel, MsgCodes(msgs));
      if r <> abOK then continue;
      Inc(loaded);
      model.Add('== ' + rel);
      dump.Clear;
      // keep the reference small: very large invoices are cut after 50 lines
      big := inv;
      if Length(big.Lines) > 50 then begin
        SetLength(big.Lines, 50);
        dump.Add(Format('(%d Positionen, gekürzt auf 50)', [Length(inv.Lines)]));
      end;
      if Length(big.Unmapped) > 50 then begin
        SetLength(big.Unmapped, 50);
      end;
      DumpInvoice(big, false, true, dump);
      model.AddStrings(dump);
      for j := 0 to High(inv.Unmapped) do begin
        path := inv.Unmapped[j];
        k := Pos(' = ', path);
        if k > 0 then begin
          SetLength(path, k - 1);
        end;
        key := SyntaxNames[inv.Info.Syntax] + ' ' + path;
        k := stats.IndexOf(key);
        if k < 0 then k := stats.AddObject(key, TObject(0));
        stats.Objects[k] := TObject(NativeInt(stats.Objects[k]) + 1);
      end;
      // remember normalized dumps of KoSIT CII/UBL pairs
      if (Pos('kosit/', rel) = 1) then begin
        dump.Clear;
        DumpInvoice(inv, true, false, dump);
        pairs.Values[rel] := StringReplace(dump.Text, #13#10, #10, [rfReplaceAll]);
      end;
    end;
    sw.Stop;
    Writeln(Format('  %d Rechnungen gelesen in %d ms', [loaded, sw.ElapsedMilliseconds]));

    // The KoSIT testsuite has most cases in both syntaxes. The pairs are not
    // always identical in content, so the differences are kept as reference:
    // a parser change that alters them shows up here.
    pairCount := 0;
    pairDiffs := 0;
    dump.Clear;
    for i := 0 to pairs.Count - 1 do begin
      rel := pairs.Names[i];
      if Pos('_uncefact.xml', rel) = 0 then continue;
      partner := StringReplace(rel, '_uncefact.xml', '_ubl.xml', []);
      if pairs.IndexOfName(partner) < 0 then continue;
      Inc(pairCount);
      dump.Add('== ' + StringReplace(rel, '_uncefact.xml', '', []));
      a.Text := pairs.ValueFromIndex[i];
      b.Text := pairs.Values[partner];
      k := 0;
      for j := 0 to a.Count - 1 do begin
        if b.IndexOf(a[j]) < 0 then begin
          Inc(k);
          dump.Add('CII: ' + a[j]);
        end;
      end;
      for j := 0 to b.Count - 1 do begin
        if a.IndexOf(b[j]) < 0 then begin
          Inc(k);
          dump.Add('UBL: ' + b[j]);
        end;
      end;
      if k > 0 then Inc(pairDiffs);
    end;
    Writeln(Format('  %d KoSIT-Paare CII/UBL verglichen, %d gleich', [pairCount, pairCount - pairDiffs]));
    CompareSections('crosscheck.txt', dump, Update);

    CompareSections('model.txt', model, Update);

    dump.Clear;
    dump.Add('== nicht abgebildete Elemente (Anzahl, Syntax, Pfad)');
    for i := 0 to stats.Count - 1 do begin
      dump.Add(Format('%5d  %s', [NativeInt(stats.Objects[i]), stats[i]]));
    end;
    CompareSections('unmapped.txt', dump, Update);
  finally
    b.Free;
    a.Free;
    dump.Free;
    pairs.Free;
    stats.Free;
    model.Free;
    files.Free;
  end;
end;

const
  SevChar: array[TAbSeverity] of string = ('I', 'W', 'E');

procedure RunCheck(Update: Boolean);
var
  files, out, stats, applied, failed: TStringList;
  dir, rel, key, html, bad: string;
  i, j, k, clean, withErrors: Integer;
  counts: array[TAbRuleStatus] of Integer;
  st: TAbRuleStatus;
  inv: TEInvoice;
  rep: TAbCheckReport;
  r: TAbResult;
  sw: TStopwatch;
begin
  Writeln('Prüfung (Korpus)');
  dir := Root + 'testdata' + PathDelim + 'external';
  if not DirectoryExists(dir) then begin
    Writeln('  übersprungen: ', dir, ' fehlt');
    exit;
  end;
  files := TStringList.Create;
  out := TStringList.Create;
  stats := TStringList.Create;
  applied := TStringList.Create;
  failed := TStringList.Create;
  try
    ListFiles(dir, files);
    files.CaseSensitive := true;
    files.Sort;
    stats.Sorted := true;
    applied.Sorted := true;
    failed.Sorted := true;
    clean := 0;
    withErrors := 0;
    sw := TStopwatch.StartNew;
    for i := 0 to files.Count - 1 do begin
      rel := StringReplace(Copy(files[i], Length(dir) + 2, MaxInt), '\', '/', [rfReplaceAll]);
      r := TAbdecker.CheckFile(files[i], inv, rep);
      Check(r <> abInternalError, 'Prüfung ohne internen Fehler: ' + rel);
      if r <> abOK then continue;
      out.Add('== ' + rel);
      for j := 0 to High(rep.RuleSets) do begin
        out.Add('rules: ' + rep.RuleSets[j]);
      end;
      for j := 0 to High(rep.Messages) do begin
        if rep.Messages[j].Origin = aboExtra then begin
          out.Add(SevChar[rep.Messages[j].Severity] + ' ' + rep.Messages[j].Code + ' (extra) ' + rep.Messages[j].Text);
        end else begin
          out.Add(SevChar[rep.Messages[j].Severity] + ' ' + rep.Messages[j].Code + ' ' + rep.Messages[j].Text);
        end;
        if rep.Messages[j].Severity <> abInfo then begin
          key := rep.Messages[j].Code;
          k := stats.IndexOf(key);
          if k < 0 then k := stats.AddObject(key, TObject(0));
          stats.Objects[k] := TObject(NativeInt(stats.Objects[k]) + 1);
        end;
      end;
      for j := 0 to High(rep.NotChecked) do begin
        out.Add('not checked: ' + rep.NotChecked[j]);
      end;
      // status of the rules: summary per invoice, counts per rule
      for st := Low(TAbRuleStatus) to High(TAbRuleStatus) do begin
        counts[st] := 0;
      end;
      for j := 0 to High(rep.Rules) do begin
        Inc(counts[rep.Rules[j].Status]);
        key := rep.Rules[j].ID;
        if applied.IndexOf(key) < 0 then applied.AddObject(key, TObject(0));
        if failed.IndexOf(key) < 0 then failed.AddObject(key, TObject(0));
        if rep.Rules[j].Status <> arsNotApplied then begin
          k := applied.IndexOf(key);
          applied.Objects[k] := TObject(NativeInt(applied.Objects[k]) + 1);
        end;
        if rep.Rules[j].Status = arsFailed then begin
          k := failed.IndexOf(key);
          failed.Objects[k] := TObject(NativeInt(failed.Objects[k]) + 1);
        end;
      end;
      if Length(rep.Rules) > 0 then begin
        out.Add(Format('applied: %d passed, %d failed, %d not applied',
          [counts[arsPassed], counts[arsFailed], counts[arsNotApplied]]));
      end;
      bad := RulesInconsistent(rep);
      Check(bad = '', 'Befunde und Regelstatus passen zusammen: ' + rel, bad);
      if rep.Errors = 0 then begin
        Inc(clean);
      end else begin
        Inc(withErrors);
      end;
      html := TAbdecker.ToHtml(inv, 'de', false);
      Check((Pos('</html>', html) > 0) and (CountOf('<table', html) = CountOf('</table>', html)) and
        (CountOf('<div', html) = CountOf('</div>', html)), 'HTML wohlgeformt: ' + rel);
    end;
    sw.Stop;
    Writeln(Format('  %d Rechnungen geprüft in %d ms: %d ohne Fehler, %d mit Fehlern',
      [clean + withErrors, sw.ElapsedMilliseconds, clean, withErrors]));
    CompareSections('check.txt', out, Update);
    out.Clear;
    out.Add('== Meldungen im Korpus (Anzahl, Regel)');
    for i := 0 to stats.Count - 1 do begin
      out.Add(Format('%5d  %s', [NativeInt(stats.Objects[i]), stats[i]]));
    end;
    out.Add('== Regeln im Korpus (angewandt, verletzt, Regel)');
    for i := 0 to applied.Count - 1 do begin
      out.Add(Format('%5d  %5d  %s', [NativeInt(applied.Objects[i]),
        NativeInt(failed.Objects[failed.IndexOf(applied[i])]), applied[i]]));
    end;
    CompareSections('check-stats.txt', out, Update);
  finally
    failed.Free;
    applied.Free;
    stats.Free;
    out.Free;
    files.Free;
  end;
end;

{ JSON of every corpus file (InfoToJson; CheckToJson for readable invoices):
  the format shared by --json and serve }
procedure RunJson(Update: Boolean);
var
  files, out: TStringList;
  dir, rel: string;
  i: Integer;
  info: TEInvoiceInfo;
  inv: TEInvoice;
  rep: TAbCheckReport;
  msgs: TAbMessages;
  r: TAbResult;
  atts: TEInvoiceFiles;

  procedure AddText(const s: string);
  var
    l: TStringList;
  begin
    l := TStringList.Create;
    try
      l.LineBreak := #10;
      l.Text := s;
      out.AddStrings(l);
    finally
      l.Free;
    end;
  end;

begin
  Writeln('JSON (Korpus)');
  dir := Root + 'testdata' + PathDelim + 'external';
  if not DirectoryExists(dir) then begin
    Writeln('  übersprungen: ', dir, ' fehlt');
    exit;
  end;
  files := TStringList.Create;
  out := TStringList.Create;
  try
    ListFiles(dir, files);
    files.CaseSensitive := true;
    files.Sort;
    for i := 0 to files.Count - 1 do begin
      rel := StringReplace(Copy(files[i], Length(dir) + 2, MaxInt), '\', '/', [rfReplaceAll]);
      out.Add('== ' + rel);
      r := TAbdecker.Info(files[i], info, msgs);
      AddText(TAbdecker.InfoToJson(rel, r, info, msgs));
      r := TAbdecker.CheckFile(files[i], inv, rep);
      if r = abOK then begin
        AddText(TAbdecker.CheckToJson(rel, r, inv, rep));
      end;
      r := TAbdecker.Attachments(files[i], atts, msgs);
      if (r = abOK) and (Length(atts) > 0) then begin
        AddText(TAbdecker.AttachmentsToJson(rel, r, atts, msgs));
      end;
    end;
    Writeln(Format('  %d Dateien', [files.Count]));
    CompareSections('json.txt', out, Update);
  finally
    out.Free;
    files.Free;
  end;
end;

{ InvoiceToJson of every readable corpus invoice; each must be valid JSON }
procedure RunInvoiceJson(Update: Boolean);
var
  files, out, l: TStringList;
  dir, rel, s: string;
  i, bad: Integer;
  inv: TEInvoice;
  msgs: TAbMessages;
  doc: TJDoc;
begin
  Writeln('Rechnung als JSON (Korpus)');
  dir := Root + 'testdata' + PathDelim + 'external';
  if not DirectoryExists(dir) then begin
    Writeln('  übersprungen: ', dir, ' fehlt');
    exit;
  end;
  files := TStringList.Create;
  out := TStringList.Create;
  l := TStringList.Create;
  try
    l.LineBreak := #10;
    ListFiles(dir, files);
    files.CaseSensitive := true;
    files.Sort;
    bad := 0;
    for i := 0 to files.Count - 1 do begin
      if TAbdecker.Load(files[i], inv, msgs) <> abOK then continue;
      rel := StringReplace(Copy(files[i], Length(dir) + 2, MaxInt), '\', '/', [rfReplaceAll]);
      s := TAbdecker.InvoiceToJson(rel, abOK, inv, msgs);
      if not JsonParse(TEncoding.UTF8.GetBytes(s), doc) then begin
        Inc(bad);
        Writeln('  kein gültiges JSON: ', rel, ': ', doc.Error);
      end;
      out.Add('== ' + rel);
      // keep the reference small: very large invoices are cut after 50 lines
      // (the validity check above covers all of them)
      if Length(inv.Lines) > 50 then begin
        out.Add(Format('(%d Positionen, gekürzt auf 50)', [Length(inv.Lines)]));
        SetLength(inv.Lines, 50);
        s := TAbdecker.InvoiceToJson(rel, abOK, inv, msgs);
      end;
      l.Text := s;
      out.AddStrings(l);
    end;
    Check(bad = 0, 'Rechnung als JSON: gültiges JSON', IntToStr(bad));
    CompareSections('invoice.txt', out, Update);
  finally
    l.Free;
    out.Free;
    files.Free;
  end;
end;

{ What is to be paid, for every readable corpus invoice (tests/golden/girocode.txt);
  the GiroCode texts are also input of tests/qr.py }
procedure RunGiroCode(Update: Boolean);
const
  KindNames: array[TPayKind] of string = ('none', 'transfer', 'direct-debit', 'nothing-to-pay', 'credit', 'other');
  NoCodeNames: array[TPayNoCode] of string = ('', 'currency', 'no-account', 'no-iban', 'iban', 'amount', 'name',
    'too-long');
var
  files, out: TStringList;
  dir, rel, s: string;
  i, j, codes: Integer;
  inv: TEInvoice;
  msgs: TAbMessages;
  p: TPayInfo;
  qr: TQrCode;

  function Esc(const s: string): string;
  begin
    result := StringReplace(s, #10, '\n', [rfReplaceAll]);
  end;

  procedure AddCode(const s: string);
  begin
    out.Add('code: ' + Esc(s));
    Inc(codes);
    Check(QrEncode(U8(s), qr) and (qr.Version <= 13), 'GiroCode höchstens Version 13: ' + rel);
  end;

begin
  Writeln('Zahlung und GiroCode (Korpus)');
  dir := Root + 'testdata' + PathDelim + 'external';
  if not DirectoryExists(dir) then begin
    Writeln('  übersprungen: ', dir, ' fehlt');
    exit;
  end;
  files := TStringList.Create;
  out := TStringList.Create;
  try
    ListFiles(dir, files);
    files.CaseSensitive := true;
    files.Sort;
    codes := 0;
    for i := 0 to files.Count - 1 do begin
      if TAbdecker.Load(files[i], inv, msgs) <> abOK then continue;
      rel := StringReplace(Copy(files[i], Length(dir) + 2, MaxInt), '\', '/', [rfReplaceAll]);
      p := PaymentInfo(inv);
      out.Add('== ' + rel);
      s := 'kind: ' + KindNames[p.Kind];
      if p.Amount.Present then s := s + ' ' + p.Amount.ToString + ' ' + p.Currency;
      out.Add(s);
      if p.Kind <> pkTransfer then continue;
      if p.IBAN <> '' then begin
        s := 'iban: ' + p.IBAN;
        if not p.IsIBAN then s := 'account: ' + p.IBAN else if not p.IBANValid then s := s + ' (invalid)';
        out.Add(s);
      end;
      if p.OtherAccounts > 0 then out.Add('other accounts: ' + IntToStr(p.OtherAccounts));
      if p.Code <> '' then AddCode(p.Code) else out.Add('no code: ' + NoCodeNames[p.NoCode]);
      for j := 0 to High(p.Discounts) do begin
        out.Add(Format('skonto: %s %% %d days until %s: %s', [p.Discounts[j].Percent.ToString, p.Discounts[j].Days,
          p.Discounts[j].Deadline, p.Discounts[j].Amount.ToString]));
        if p.Discounts[j].Code <> '' then AddCode(p.Discounts[j].Code);
      end;
    end;
    Writeln(Format('  %d GiroCodes', [codes]));
    CompareSections('girocode.txt', out, Update);
  finally
    out.Free;
    files.Free;
  end;
end;

{ The version in the abdecker mark of an XML replaced by '*' }
function MaskVersion(const Xml: TBytes): string;
var
  p, q: Integer;
begin
  result := TEncoding.UTF8.GetString(Xml);
  p := Pos('<!-- abdecker ', result);
  if p = 0 then exit;
  p := p + Length('<!-- abdecker ');
  q := Pos(' by ', result, p);
  if q > 0 then result := Copy(result, 1, p - 1) + '*' + Copy(result, q, MaxInt);
end;

{ Writer, templates: reading tests/templates/<name>.xml and writing it again
  gives the file byte for byte (the files are written in the writer's form),
  apart from the version in the abdecker mark }
procedure TestWriter;
var
  files: TStringList;
  i: Integer;
  name: string;
  inv: TEInvoice;
  msgs: TAbMessages;
  rep: TAbCheckReport;
  xml, expected: TBytes;
  r: TAbResult;
begin
  Writeln('Writer (CII)');
  files := TStringList.Create;
  try
    ListFiles(Root + 'tests' + PathDelim + 'templates', files);
    files.Sort;

    for i := 0 to files.Count - 1 do begin
      name := ChangeFileExt(ExtractFileName(files[i]), '');
      expected := ReadFileBytes(files[i]);
      r := TAbdecker.LoadFromBytes(expected, inv, msgs);
      Check(r = abOK, name + ': lesbar');
      r := TAbdecker.WriteCII(inv, xml, rep);
      Check((r = abOK) and (rep.Errors = 0) and (rep.Warnings = 0), name + ': geschrieben und fehlerfrei', Codes(rep));
      Check(MaskVersion(xml) = MaskVersion(expected), name + ': Byte für Byte gleich',
        FirstDiff(MaskVersion(xml), MaskVersion(expected)));
    end;
  finally
    files.Free;
  end;

  inv := ValidInvoice;
  inv.Lines[0].ItemName := '  Name  ';
  r := TAbdecker.WriteCII(inv, xml, rep);
  Check(r = abOK, 'Writer: Werte getrimmt wie beim Lesen', Codes(rep));
  Check(Pos('<ram:Name>Name</ram:Name>', TEncoding.UTF8.GetString(xml)) > 0, 'Writer: getrimmter Wert im XML');

  // check findings do not stop the output
  inv := ValidInvoice;
  inv.Number := '';
  r := TAbdecker.WriteCII(inv, xml, rep);
  Check((r = abOK) and (Length(xml) > 0) and HasMsg(rep.Messages, 'BR-02'), 'Writer: XML trotz Prüffehler',
    Codes(rep));

  // escaping
  inv := ValidInvoice;
  inv.Seller.Name := 'A & B <C> "D"';
  inv.PaymentTerms := 'Zeile 1'#13#10'Zeile 2';
  r := TAbdecker.WriteCII(inv, xml, rep);
  Check((r = abOK) and (Pos('<ram:Name>A &amp; B &lt;C&gt; "D"</ram:Name>', TEncoding.UTF8.GetString(xml)) > 0) and
    (Pos('Zeile 1&#13;'#10'Zeile 2', TEncoding.UTF8.GetString(xml)) > 0), 'Writer: Sonderzeichen', Codes(rep));

  // the self-check catches what CII has no place for (a VAT point date without VAT breakdown)
  inv := ValidInvoice;
  inv.Taxes := nil;
  inv.TaxPointDate := '2026-01-01';
  r := TAbdecker.WriteCII(inv, xml, rep);
  Check((r = abInternalError) and (Length(xml) = 0) and HasMsg(rep.Messages, 'CII-VERIFY'),
    'Writer: Selbstkontrolle schlägt an', Codes(rep));

  inv := ValidInvoice;
  inv.Payment.CardNumber := 'a'#1'b';
  r := TAbdecker.WriteCII(inv, xml, rep);
  Check((r = abUnsupported) and (Length(xml) = 0) and HasMsg(rep.Messages, 'CII-CHAR'),
    'Writer: Steuerzeichen abgelehnt', Codes(rep));
end;

{ Writer, corpus round trip: every readable invoice (CII, UBL, ZUGFeRD 1.0)
  -> CII -> model, the model must stay the same (WriteCII's self-check). For
  CII the check must give the same findings as the original. }
procedure RunWriteCorpus;
var
  files: TStringList;
  dir, rel: string;
  i, n, same, changed: Integer;
  inv, back: TEInvoice;
  rep, rep2: TAbCheckReport;
  xml: TBytes;
  r: TAbResult;
  sw: TStopwatch;
begin
  Writeln('Writer (Korpus-Rundlauf)');
  dir := Root + 'testdata' + PathDelim + 'external';
  if not DirectoryExists(dir) then begin
    Writeln('  übersprungen: ', dir, ' fehlt');
    exit;
  end;
  files := TStringList.Create;
  try
    ListFiles(dir, files);
    files.CaseSensitive := true;
    files.Sort;
    n := 0;
    same := 0;
    changed := 0;
    sw := TStopwatch.StartNew;
    for i := 0 to files.Count - 1 do begin
      rel := StringReplace(Copy(files[i], Length(dir) + 2, MaxInt), '\', '/', [rfReplaceAll]);
      if TAbdecker.CheckFile(files[i], inv, rep) <> abOK then continue;
      Inc(n);
      r := TAbdecker.WriteCII(inv, xml, rep2);
      Check(r = abOK, 'Rundlauf: ' + rel, Codes(rep2));
      if (r <> abOK) or (inv.Info.Syntax <> eisynCII) then continue;
      // same findings, apart from what only the PDF container reports
      Check(TAbdecker.LoadFromBytes(xml, back, rep.Messages) = abOK, 'Rundlauf lesbar: ' + rel);
      TAbdecker.Check(inv, rep);
      TAbdecker.Check(back, rep2);
      if Codes(rep) = Codes(rep2) then begin
        Inc(same);
      end else begin
        Inc(changed);
        Writeln('  Prüfung anders: ', rel, #10'    vorher:  ', Codes(rep), #10'    nachher: ', Codes(rep2));
      end;
    end;
    sw.Stop;
    Writeln(Format('  %d Rechnungen geschrieben in %d ms; CII: %d mit gleicher Prüfung, %d anders',
      [n, sw.ElapsedMilliseconds, same, changed]));
    Check(changed = 0, 'Rundlauf: Prüfung unverändert (CII)', IntToStr(changed));
  finally
    files.Free;
  end;
end;

{ InvoiceFromJson on a text, today = 2026-11-14 }
function FromJson(const s: string; out Inv: TEInvoice; out Msgs: TAbMessages; const Vars: string = ''): TAbResult;
var
  o: TAbJsonOptions;
  l: TStringList;
  i: Integer;
begin
  o := Default(TAbJsonOptions);
  o.Today := '2026-11-14';
  l := TStringList.Create;
  try
    l.Delimiter := '|';
    l.StrictDelimiter := true;
    l.DelimitedText := Vars;
    SetLength(o.Vars, l.Count);
    for i := 0 to l.Count - 1 do begin
      o.Vars[i] := l[i];
    end;
  finally
    l.Free;
  end;
  result := TAbdecker.InvoiceFromJson(TEncoding.UTF8.GetBytes(s), o, Inv, Msgs);
end;

{ text of the messages, for Pos checks }
function MsgTexts(const Msgs: TAbMessages): string;
var
  i: Integer;
begin
  result := '';
  for i := 0 to High(Msgs) do begin
    result := result + Msgs[i].Code + ' ' + Msgs[i].Text + #10;
  end;
end;

{ Creating from the own JSON format: every templates/<name>.json gives exactly
  tests/templates/<name>.xml (today fixed), plus the errors of the format }
procedure TestCreate;
const
  Base = '{"number": "1", "issueDate": "2026-11-14", "paymentTerms": "Sofort", "seller": {"name": "S", ' +
    '"vatId": "DE123456788", ' +
    '"iban": "DE02120300000000202051"}, "buyer": {"name": "B"}, "lines": [%s]%s}';
  Line1 = '{"name": "A", "quantity": 1, "unit": "piece", "price": 10, "vat": 19}';
var
  files: TStringList;
  i: Integer;
  name: string;
  o: TAbJsonOptions;
  inv: TEInvoice;
  msgs: TAbMessages;
  rep: TAbCheckReport;
  xml: TBytes;
  r: TAbResult;
  s: string;
begin
  Writeln('Erstellen (JSON)');
  files := TStringList.Create;
  try
    ListFiles(Root + 'tests' + PathDelim + 'templates', files);
    files.Sort;

    for i := 0 to files.Count - 1 do begin
      name := ChangeFileExt(ExtractFileName(files[i]), '');
      o := Default(TAbJsonOptions);
      o.Today := '2026-11-14';
      r := TAbdecker.InvoiceFromJson(ReadFileBytes(Root + 'templates' + PathDelim + name + '.json'), o, inv, msgs);
      Check(r = abOK, name + '.json: gelesen', MsgTexts(msgs));
      if r <> abOK then continue;
      r := TAbdecker.WriteCII(inv, xml, rep);
      Check((r = abOK) and (Length(rep.Messages) = 0), name + '.json: geschrieben und fehlerfrei', Codes(rep));
      Check(MaskVersion(xml) = MaskVersion(ReadFileBytes(files[i])), name + '.json: ergibt genau ' + name + '.xml',
        FirstDiff(MaskVersion(xml), MaskVersion(ReadFileBytes(files[i]))));
    end;
  finally
    files.Free;
  end;

  // calculation: rounding per line and per VAT rate, mixed rates
  r := FromJson(Format(Base, ['{"name": "A", "quantity": 3, "unit": "piece", "price": 0.335, "vat": 19}, ' +
    '{"name": "B", "quantity": 1, "unit": "piece", "price": 9.99, "vat": 7}, ' + Line1, '']), inv, msgs);
  Check((r = abOK) and (inv.Lines[0].NetAmount.ToString = '1.01') and (Length(inv.Taxes) = 2) and
    (inv.Taxes[0].TaxableAmount.ToString = '11.01') and (inv.Taxes[0].TaxAmount.ToString = '2.09') and
    (inv.Taxes[1].TaxAmount.ToString = '0.70') and (inv.Totals.TaxExclusive.ToString = '21.00') and
    (inv.Totals.DuePayable.ToString = '23.79') and (inv.Lines[2].ID = '3'), 'Erstellen: Rechnen und Runden',
    MsgTexts(msgs));
  TAbdecker.WriteCII(inv, xml, rep);
  Check(rep.Errors = 0, 'Erstellen: gemischte Sätze ohne Prüffehler', Codes(rep));

  // placeholders
  r := FromJson(StringReplace(Format(Base, [Line1, ', "dueDate": "{{today+30}}", "period": {"start": ' +
    '"{{prevMonthStart}}", "end": "{{ prevMonthEnd }}"}, "orderReference": "{{po}}"']), '"number": "1"',
    '"number": "{{nr}}"', []), inv, msgs, 'nr=2026-0001|po=PO {x}');
  Check((r = abOK) and (inv.Number = '2026-0001') and (inv.DueDate = '2026-12-14') and
    (inv.PeriodStart = '2026-10-01') and (inv.PeriodEnd = '2026-10-31') and (inv.OrderRef = 'PO {x}'),
    'Erstellen: Platzhalter', MsgTexts(msgs));
  r := FromJson(Format(Base, ['{"name": "A", "quantity": "{{h}}", "unit": "hour", "price": 95, "vat": 19}', '']),
    inv, msgs, 'h=7.5');
  Check((r = abOK) and (inv.Lines[0].NetAmount.ToString = '712.50'), 'Erstellen: Zahl aus Platzhalter',
    MsgTexts(msgs));
  r := FromJson(Format(Base, [Line1, ', "note": "{{unbekannt}}"']), inv, msgs);
  Check((r = abInvalidData) and HasMsg(msgs, 'JSON-PLACEHOLDER') and (Pos('note: unknown placeholder', MsgTexts(msgs)) > 0),
    'Erstellen: unbekannter Platzhalter', MsgTexts(msgs));
  r := FromJson(Format(Base, [Line1, ', "issueDate": "{{today}}"']), inv, msgs);
  Check((r = abInvalidData) and HasMsg(msgs, 'JSON-DUPLICATE'), 'Erstellen: doppeltes Feld', MsgTexts(msgs));

  // errors of the format, all at once, with line and column
  s := '{"number": "1",'#10'  "isueDate": "2026-11-14",'#10'  "dueDate": "2026-13-01",'#10 +
    '  "seller": {"name": 5, "iban": "X"},'#10'  "buyer": {"name": "B"},'#10 +
    '  "lines": [{"name": "A", "quantity": "1,5", "unit": "hour", "price": 1e3}]}';
  r := FromJson(s, inv, msgs);
  s := MsgTexts(msgs);
  Check((r = abInvalidData) and (Pos('JSON-FIELD line 2, column 3: isueDate: unknown field', s) > 0) and
    (Pos('JSON-VALUE line 3, column 14: dueDate: "2026-13-01" is not a date', s) > 0) and
    (Pos('JSON-TYPE line 4, column 22: seller.name: a string expected', s) > 0) and
    (Pos('lines[1].quantity: "1,5" is not a number', s) > 0) and (Pos('lines[1].price: "1e3"', s) > 0) and
    (Pos('JSON-MISSING line 6, column 13: lines[1].vat: required', s) > 0), 'Erstellen: alle Fehler mit Position', s);
  r := FromJson('{"lines": [}', inv, msgs);
  Check((r = abInvalidData) and HasMsg(msgs, 'JSON-SYNTAX') and (Length(inv.Lines) = 0), 'Erstellen: kaputtes JSON',
    MsgTexts(msgs));
  r := FromJson(Format(Base, [Line1, ', "totals": {"net": 10.00, "vat": 1.91}']), inv, msgs);
  Check((r = abInvalidData) and (Pos('totals.vat: 1.91 given, 1.90 calculated', MsgTexts(msgs)) > 0),
    'Erstellen: Summen zur Kontrolle', MsgTexts(msgs));
  r := FromJson(StringReplace(Format(Base, [Line1, '']), ', "iban": "DE02120300000000202051"', '', []), inv, msgs);
  Check((r = abInvalidData) and (Pos('seller.iban: required', MsgTexts(msgs)) > 0), 'Erstellen: Rechnung ohne IBAN',
    MsgTexts(msgs));
  r := FromJson(Format(Base, [StringReplace(Line1, '"vat": 19', '"vat": 19', []), ', "vatMode": "reverse-charge"']),
    inv, msgs);
  Check((r = abInvalidData) and (Pos('lines[1].vat: not allowed', MsgTexts(msgs)) > 0), 'Erstellen: vat bei Reverse Charge',
    MsgTexts(msgs));
  r := FromJson(Format(Base, [Line1, ', "attachments": [{"file": "x.pdf"}]']), inv, msgs);
  Check((r = abInvalidData) and (Pos('files cannot be read here', MsgTexts(msgs)) > 0), 'Erstellen: Datei ohne BaseDir',
    MsgTexts(msgs));
  r := FromJson(Format(Base, [Line1, ', "attachments": [{"name": "a.pdf", "content": "JVBERi0xLjQK", ' +
    '"description": "Nachweis"}]']), inv, msgs);
  Check((r = abOK) and (Length(inv.Documents) = 1) and (inv.Documents[0].MimeType = 'application/pdf') and
    (TEncoding.ASCII.GetString(inv.Documents[0].Content) = '%PDF-1.4'#10), 'Erstellen: Anhang base64', MsgTexts(msgs));
  r := FromJson(Format(Base, [Line1, ', "attachments": [{"name": "a.exe", "content": "AAAA"}]']), inv, msgs);
  Check((r = abInvalidData) and HasMsg(msgs, 'JSON-ATTACHMENT'), 'Erstellen: Dateityp abgelehnt', MsgTexts(msgs));
  o := Default(TAbJsonOptions);
  o.Today := '14.11.2026';
  r := TAbdecker.InvoiceFromJson(TEncoding.UTF8.GetBytes('{}'), o, inv, msgs);
  Check((r = abInvalidData) and HasMsg(msgs, 'JSON-OPTION'), 'Erstellen: ungültiges heute', MsgTexts(msgs));
end;

function JP(const s: string; out Doc: TJDoc): Boolean;
begin
  result := JsonParse(TEncoding.UTF8.GetBytes(s), Doc);
end;

function JsonFails(const s: string): Boolean;
var
  doc: TJDoc;
begin
  result := not JP(s, doc) and (doc.Error <> '');
end;

{ InvoiceToJson: reduced view, empty fields left out, numbers as in the
  invoice, valid JSON, array positions kept }
procedure TestInvoiceJson;
var
  inv: TEInvoice;
  msgs: TAbMessages;
  s: string;
  doc: TJDoc;
  n: Integer;
  l: TStringList;

  function Val(const APath: string): string;
  var
    k: Integer;
  begin
    k := doc.Path(0, APath);
    if k < 0 then exit('<fehlt>');
    result := doc.Nodes[k].Value;
  end;

begin
  Writeln('InvoiceToJson');
  l := TStringList.Create;
  try
    l.LoadFromFile(Root + 'templates' + PathDelim + 'minimal.json', TEncoding.UTF8);
    s := l.Text;
  finally
    l.Free;
  end;
  Check(FromJson(s, inv, msgs) = abOK, 'IJ Vorlage', MsgTexts(msgs));
  s := TAbdecker.InvoiceToJson('minimal.json', abOK, inv, nil);
  Check(JP(s, doc), 'IJ gültiges JSON', doc.Error);
  Check(Val('result') = 'ok', 'IJ result');
  Check(Val('invoice/issueDate') = '2026-11-14', 'IJ issueDate', Val('invoice/issueDate'));
  Check(Val('invoice/typeCode') = '380', 'IJ typeCode');
  Check(Val('invoice/seller/country') = 'DE', 'IJ seller.country');
  Check(Val('invoice/paymentMeans') = '58', 'IJ paymentMeans');
  Check(Val('invoice/totals/gross') = '3852.27', 'IJ totals.gross', Val('invoice/totals/gross'));
  Check(doc.Nodes[doc.Path(0, 'invoice/totals/gross')].Kind = jkNumber, 'IJ Betrag als Zahl');
  Check(doc.Path(0, 'invoice/buyerReference') < 0, 'IJ leeres Feld fehlt');
  Check(doc.Path(0, 'invoice/allowancesCharges') < 0, 'IJ leere Liste fehlt');
  n := doc.Path(0, 'invoice/lines');
  n := doc.Nodes[n].FirstChild;
  Check((n >= 0) and (doc.Nodes[doc.Member(n, 'unit')].Value = 'HUR'), 'IJ unit als Code');
  Check((n >= 0) and (doc.Nodes[doc.Member(n, 'net')].Value = '3087.50'), 'IJ net je Position');
  Check(doc.Nodes[doc.Path(0, 'messages')].FirstChild < 0, 'IJ keine Meldungen');

  // unusable number: left out with a warning; empty line: stays as {}
  inv.Lines[1].NetPrice := TAbDecimal.Parse('9,50');
  inv.Lines[0] := Default(TEInvoiceLine);
  s := TAbdecker.InvoiceToJson('', abOK, inv, nil);
  Check(JP(s, doc), 'IJ gültiges JSON (Fehlerfälle)', doc.Error);
  Check(Pos('"JSON-NUMBER"', s) > 0, 'IJ JSON-NUMBER');
  Check(Pos('lines[2].price: \"9,50\"', s) > 0, 'IJ Pfad in der Meldung', s);
  n := doc.Nodes[doc.Path(0, 'invoice/lines')].FirstChild;
  Check((n >= 0) and (doc.Nodes[n].Kind = jkObject) and (doc.Nodes[n].FirstChild < 0), 'IJ leere Position bleibt');
  n := doc.Nodes[n].Next;
  Check((n >= 0) and (doc.Member(n, 'price') < 0) and (doc.Member(n, 'quantity') >= 0), 'IJ Preis fehlt');

  // failure: empty invoice, result and messages
  SetLength(msgs, 1);
  msgs[0] := Default(TAbMessage);
  msgs[0].Code := 'PDF-NO-INVOICE';
  s := TAbdecker.InvoiceToJson('x.pdf', abNoInvoice, Default(TEInvoice), msgs);
  Check(JP(s, doc), 'IJ gültiges JSON (no-invoice)', doc.Error);
  Check(Val('result') = 'no-invoice', 'IJ result no-invoice');
  Check(doc.Nodes[doc.Path(0, 'invoice')].FirstChild < 0, 'IJ invoice leer');
  Check(Pos('PDF-NO-INVOICE', s) > 0, 'IJ Meldung');
end;

{ JSON reader: structure, numbers as text, strings, errors with position }
procedure TestJsonRead;
var
  doc: TJDoc;
  n, i: Integer;
  s: string;
begin
  Writeln('JSON lesen');
  Check(JP('{"a": 1, "b": [true, false, null], "c": {"d": "x"}}', doc) and (doc.Count = 8), 'JSON: Struktur', doc.Error);
  Check((doc.Nodes[0].Kind = jkObject) and (doc.Nodes[doc.Member(0, 'a')].Value = '1') and
    (doc.Nodes[doc.Path(0, 'c/d')].Value = 'x') and (doc.Path(0, 'c/e') < 0) and (doc.Member(0, 'A') < 0),
    'JSON: Member und Path');
  n := doc.Member(0, 'b');
  Check((doc.Nodes[n].Kind = jkArray) and (doc.Nodes[doc.Nodes[n].FirstChild].Kind = jkTrue) and
    (doc.Nodes[doc.Nodes[n].LastChild].Kind = jkNull) and (doc.Nodes[doc.Nodes[n].LastChild].Parent = n),
    'JSON: Array');

  Check(JP('[0.10, -1.5e3, 32.5, 0, 12345678901234567890123]', doc), 'JSON: Zahlen', doc.Error);
  s := '';
  n := doc.Nodes[0].FirstChild;
  while n >= 0 do begin
    s := s + doc.Nodes[n].Value + ' ';
    n := doc.Nodes[n].Next;
  end;
  Check(s = '0.10 -1.5e3 32.5 0 12345678901234567890123 ', 'JSON: Zahlen als Text, exakt', s);

  Check(JP('"aä😀\n\"\\\/\t" ', doc) and (doc.Nodes[0].Value = 'aä😀'#10'"\/'#9),
    'JSON: Escapes und Surrogatpaar', doc.Error);
  Check(JP('"Größe € 😀"', doc) and (doc.Nodes[0].Value = 'Größe € 😀'), 'JSON: UTF-8');
  Check(JsonParse(Concat(TBytes.Create($EF, $BB, $BF), TEncoding.UTF8.GetBytes('{}')), doc), 'JSON: BOM');

  // errors with line and column (in characters)
  Check(not JP('{'#10'  "a": 1,'#10'  "b": }', doc) and (doc.ErrorLine = 3) and (doc.ErrorCol = 8) and
    (Pos('line 3, column 8', doc.Error) > 0), 'JSON: Fehler mit Zeile und Spalte', doc.Error);
  Check(not JP('{"ä": x}', doc) and (doc.ErrorLine = 1) and (doc.ErrorCol = 7), 'JSON: Spalte in Zeichen', doc.Error);
  Check(JP('{'#13#10'  "a": 7}', doc) and (doc.Nodes[1].Line = 2) and (doc.Nodes[1].Col = 8),
    'JSON: Position eines Werts');

  Check(JsonFails(''), 'JSON: leer');
  Check(JsonFails('[1,]'), 'JSON: Komma am Ende');
  Check(JsonFails('{"a": 1,}'), 'JSON: Komma am Ende im Objekt');
  Check(JsonFails('// x'#10'{}'), 'JSON: Kommentar');
  Check(JsonFails('01'), 'JSON: führende Null');
  Check(JsonFails('1.'), 'JSON: Punkt ohne Ziffer');
  Check(JsonFails('[1] x'), 'JSON: Text nach dem Wert');
  Check(JsonFails('{a: 1}'), 'JSON: Name ohne Anführungszeichen');
  Check(JsonFails('"a'#9'b"'), 'JSON: Steuerzeichen im String');
  Check(JsonFails('"\ud800"') and JsonFails('"\udc00\ud800"'), 'JSON: einzelnes Surrogat');
  Check(JsonFails('"\x"'), 'JSON: unbekanntes Escape');
  Check(not JsonParse(TBytes.Create($22, $C0, $AF, $22), doc), 'JSON: ungültiges UTF-8 (überlang)');
  Check(not JsonParse(TBytes.Create($22, $ED, $A0, $80, $22), doc), 'JSON: ungültiges UTF-8 (Surrogat)');
  Check(JsonFails('True') and JsonFails('nul'), 'JSON: Literale');

  s := '';
  for i := 1 to 512 do begin
    s := '[' + s + ']';
  end;
  Check(JP('[' + s + ']', doc) = false, 'JSON: zu tief verschachtelt');
  Check(JP(s, doc), 'JSON: 512 Ebenen gehen', doc.Error);
end;

{ JSONTestSuite (test_parsing): y_ must be accepted, n_ rejected; i_
  (implementation defined) goes into jsonsuite.txt }
procedure RunJsonSuite(Update: Boolean);
var
  dir, name: string;
  sr: TSearchRec;
  names, out: TStringList;
  i, y, n: Integer;
  doc: TJDoc;
  ok: Boolean;
begin
  Writeln('JSON (JSONTestSuite)');
  dir := Root + 'testdata' + PathDelim + 'external' + PathDelim + 'jsontestsuite' + PathDelim;
  if not DirectoryExists(dir) then begin
    Writeln('  übersprungen: ', dir, ' fehlt');
    exit;
  end;
  names := TStringList.Create;
  out := TStringList.Create;
  try
    if FindFirst(dir + '*.json', faAnyFile, sr) = 0 then begin
      try
        repeat
          names.Add(sr.Name);
        until FindNext(sr) <> 0;
      finally
        FindClose(sr);
      end;
    end;
    names.CaseSensitive := true;
    names.Sort;
    y := 0;
    n := 0;
    for i := 0 to names.Count - 1 do begin
      name := names[i];
      ok := JsonParse(ReadFileBytes(dir + name), doc);
      if Copy(name, 1, 2) = 'y_' then begin
        Inc(y);
        Check(ok, 'JSONTestSuite akzeptiert: ' + name, doc.Error);
      end else if Copy(name, 1, 2) = 'n_' then begin
        Inc(n);
        Check(not ok, 'JSONTestSuite abgelehnt: ' + name);
      end else begin
        out.Add('== ' + name);
        if ok then begin
          out.Add('accepted');
        end else begin
          out.Add('rejected: ' + doc.Error);
        end;
      end;
    end;
    Writeln(Format('  %d gültige, %d ungültige, %d implementierungsabhängige Dateien', [y, n, out.Count div 2]));
    CompareSections('jsonsuite.txt', out, Update);
  finally
    out.Free;
    names.Free;
  end;
end;

{ abdeckertests --qr <in> <out>: for tests/qr.py. In: one text per line,
  hex of the UTF-8 bytes, optionally followed by a space and a mask. Out: per
  text a line "version mask", then the rows as 0/1, then an empty line;
  "too long" if it does not fit. }
procedure QrDump(const InFile, OutFile: string);
var
  inp, out: TStringList;
  i, k, x, y, mask: Integer;
  hex, row: string;
  data: TBytes;
  qr: TQrCode;
begin
  inp := TStringList.Create;
  out := TStringList.Create;
  try
    inp.LoadFromFile(InFile, TEncoding.UTF8);
    for i := 0 to inp.Count - 1 do begin
      hex := inp[i];
      mask := -1;
      k := Pos(' ', hex);
      if k > 0 then begin
        mask := StrToInt(Copy(hex, k + 1, MaxInt));
        hex := Copy(hex, 1, k - 1);
      end;
      SetLength(data, Length(hex) div 2);
      for k := 0 to High(data) do begin
        data[k] := StrToInt('$' + Copy(hex, 2 * k + 1, 2));
      end;
      if not QrEncode(data, qr, mask) then begin
        out.Add('too long');
      end else begin
        out.Add(IntToStr(qr.Version) + ' ' + IntToStr(qr.Mask));
        for y := 0 to qr.Size - 1 do begin
          row := '';
          for x := 0 to qr.Size - 1 do begin
            if qr.Dark(x, y) then row := row + '1' else row := row + '0';
          end;
          out.Add(row);
        end;
      end;
      out.Add('');
    end;
    SaveLines(out, OutFile);
  finally
    out.Free;
    inp.Free;
  end;
end;

function UpdateMode: Boolean;
var
  i: Integer;
begin
  for i := 1 to ParamCount do begin
    if (ParamStr(i) = '--update') or (ParamStr(i) = '-update') or (ParamStr(i) = '/update') then begin
      exit(true);
    end;
  end;
  result := false;
end;

begin
{$IFDEF MSWINDOWS}
  SetConsoleOutputCP(CP_UTF8);
{$ENDIF}
  SetTextCodePage(Output, CP_UTF8);
  Root := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..' + PathDelim);
  if (ParamCount = 3) and (ParamStr(1) = '--qr') then begin
    QrDump(ParamStr(2), ParamStr(3));
    exit;
  end;
  try
    TestXml;
    TestPdf;
    TestDecimal;
    TestModel;
    TestCheck;
    TestRuleStatus;
    TestEmbed;
    TestStrip;
    TestAttach;
    TestHtml;
    TestPayment;
    TestJson;
    TestJsonRead;
    TestAttachments;
    TestTemplates;
    TestWriter;
    TestCreate;
    TestInvoiceJson;
    TestMarks;
    RunCorpus(UpdateMode);
    RunModel(UpdateMode);
    RunCheck(UpdateMode);
    RunJson(UpdateMode);
    RunInvoiceJson(UpdateMode);
    RunGiroCode(UpdateMode);
    RunEditCorpus;
    RunWriteCorpus;
    RunJsonSuite(UpdateMode);
  except
    on e: Exception do begin
      Inc(Failed);
      Writeln('Abbruch: ', e.ClassName, ': ', e.Message);
    end;
  end;
  Writeln;
  Writeln(Format('%d bestanden, %d fehlgeschlagen', [Passed, Failed]));
  if Failed > 0 then ExitCode := 1;
end.
