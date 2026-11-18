{ SPDX-License-Identifier: MIT
  Copyright (c) 2026 Ingo Jache }

unit abdecker.read;

{ abdecker - format detection, the model reader shared by the syntax units
  and the dispatch to them (internal). Not part of the public API: use the
  unit abdecker. Reading the syntaxes: abdecker.cii (CII, ZUGFeRD 1.0) and
  abdecker.ubl (UBL). }

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
  abdecker, abdecker.xml;

{ Reads the invoice model from the XML tree. The readers address elements by
  local names. Every element they touch is marked as used; leaf elements
  nobody touched end up in Inv.Unmapped. }
type
  TModelReader = record
    Doc: TXDoc;
    Used: array of Boolean;
    Msgs: TAbMessages;
    procedure Init;
    function El(p: Integer; const APath: string): Integer;
    function First(p: Integer; const Name: string): Integer;
    function Next(e: Integer): Integer;   // next sibling with the same name
    function TextOf(e: Integer): string;
    function Str(p: Integer; const APath: string): string;
    function RawStr(p: Integer; const APath: string): string;  // untrimmed
    procedure Skip(p: Integer; const APath: string);  // read, but not needed in the model
    function Attr(e: Integer; const Name: string): string;
    function NumOf(e: Integer; const BT: string): TAbDecimal;
    function Num(p: Integer; const APath, BT: string): TAbDecimal;
    function DateStr(p: Integer; const APath: string): string;
    function IdentOf(e: Integer; const SchemeAttr: string): TEInvoiceID;
    function Ident(p: Integer; const APath: string): TEInvoiceID;
    function Unmapped: TAbStrings;
  end;

procedure AddID(var IDs: TEInvoiceIDs; const ID: TEInvoiceID);
procedure AddAC(var List: TEInvoiceAllowanceCharges; const AC: TEInvoiceAllowanceCharge);
procedure AppendText(var s: string; const t: string);

procedure ReadModel(const Doc: TXDoc; var Inv: TEInvoice; var Msgs: TAbMessages);
function IsPdfData(const Data: TBytes): Boolean;
function SafeAnalyze(const Data: TBytes; var Info: TEInvoiceInfo; out Xml: TBytes;
  var Doc: TXDoc; var Msgs: TAbMessages): TAbResult;

implementation

uses
  abdecker.util, abdecker.pdf, abdecker.cii, abdecker.ubl;

{ ===========================================================================
  Format and profile detection
  =========================================================================== }

const
  NS_CII = 'urn:un:unece:uncefact:data:standard:CrossIndustryInvoice:100';
  NS_ZF1 = 'urn:ferd:CrossIndustryDocument:invoice:1p0';
  NS_UBL_INVOICE = 'urn:oasis:names:specification:ubl:schema:xsd:Invoice-2';
  NS_UBL_CREDITNOTE = 'urn:oasis:names:specification:ubl:schema:xsd:CreditNote-2';
  NS_PDFAID = 'http://www.aiim.org/pdfa/ns/id/';

  // invoice file names inside the PDF, in order of preference
  KnownInvoiceNames: array[0..2] of string =
    ('factur-x.xml', 'xrechnung.xml', 'zugferd-invoice.xml');

function DetectSyntax(const Doc: TXDoc): TEInvoiceSyntax;
var
  n, ns: string;
begin
  result := eisynUnknown;
  if Doc.Count = 0 then exit;
  n := Doc.Elems[0].Name;
  ns := Doc.Elems[0].NS;
  if (n = 'CrossIndustryInvoice') and (ns = NS_CII) then begin
    result := eisynCII;
  end else if (n = 'CrossIndustryDocument') and (Pos(NS_ZF1, ns) = 1) then begin
    result := eisynZUGFeRD1;
  end else if (n = 'Invoice') and (ns = NS_UBL_INVOICE) then begin
    result := eisynUBLInvoice;
  end else if (n = 'CreditNote') and (ns = NS_UBL_CREDITNOTE) then result := eisynUBLCreditNote;
end;

function ProfileFromGuideline(const ID: string; out XRVersion: string): TEInvoiceProfile;
var
  s: string;
  i, j: Integer;
begin
  s := LowerCase(ID);
  XRVersion := '';
  i := Pos('xrechnung_', s);
  if i > 0 then begin
    j := i + 10;
    while (j <= Length(s)) and (((s[j] >= '0') and (s[j] <= '9')) or (s[j] = '.')) do begin
      Inc(j);
    end;

    XRVersion := Copy(s, i + 10, j - i - 10);
    exit(eiprofXRechnung);
  end;

  if Pos('xrechnung', s) > 0 then exit(eiprofXRechnung);
  if Pos('peppol', s) > 0 then exit(eiprofPeppol);
  if Pos('extended', s) > 0 then exit(eiprofExtended);
  if Pos('basicwl', s) > 0 then exit(eiprofBasicWL);
  if Pos('minimum', s) > 0 then exit(eiprofMinimum);
  if Pos('comfort', s) > 0 then exit(eiprofComfort);
  if Pos('basic', s) > 0 then exit(eiprofBasic);
  if Pos('urn:cen.eu:en16931:2017', s) = 1 then exit(eiprofEN16931);
  result := eiprofUnknown;
end;

{ ZUGFeRD level keys for comparing XMP and XML }
function ProfileKey(p: TEInvoiceProfile): string;
begin
  case p of
    eiprofMinimum: result := 'MINIMUM';
    eiprofBasicWL: result := 'BASICWL';
    eiprofBasic: result := 'BASIC';
    eiprofComfort, eiprofEN16931: result := 'EN16931';
    eiprofExtended: result := 'EXTENDED';
    eiprofXRechnung: result := 'XRECHNUNG';
  else
    result := '';
  end;
end;

function NormalizeLevel(const s: string): string;
var
  i: Integer;
begin
  result := '';

  for i := 1 to Length(s) do begin
    if (s[i] <> ' ') and (s[i] <> '-') and (s[i] <> '_') then result := result + s[i];
  end;

  result := UpperCase(result);
  if result = 'COMFORT' then result := 'EN16931';
end;

function FormatDate102(const s: string): string;
var
  i: Integer;
begin
  result := s;
  if Length(s) <> 8 then exit;

  for i := 1 to 8 do begin
    if (s[i] < '0') or (s[i] > '9') then exit;
  end;

  result := Copy(s, 1, 4) + '-' + Copy(s, 5, 2) + '-' + Copy(s, 7, 2);
end;

procedure FillFacts(const Doc: TXDoc; var Info: TEInvoiceInfo);
var
  t, s: Integer;
  v: string;
begin
  case Info.Syntax of
    eisynCII:
      begin
        Info.GuidelineID := Doc.Text(0, 'ExchangedDocumentContext/GuidelineSpecifiedDocumentContextParameter/ID');
        Info.InvoiceNumber := Doc.Text(0, 'ExchangedDocument/ID');
        Info.TypeCode := Doc.Text(0, 'ExchangedDocument/TypeCode');
        Info.IssueDate := FormatDate102(Doc.Text(0, 'ExchangedDocument/IssueDateTime/DateTimeString'));
        t := Doc.Path(0, 'SupplyChainTradeTransaction');
        Info.SellerName := Doc.Text(t, 'ApplicableHeaderTradeAgreement/SellerTradeParty/Name');
        Info.BuyerName := Doc.Text(t, 'ApplicableHeaderTradeAgreement/BuyerTradeParty/Name');
        s := Doc.Path(t, 'ApplicableHeaderTradeSettlement');
        Info.Currency := Doc.Text(s, 'InvoiceCurrencyCode');
        Info.GrandTotal := Doc.Text(s, 'SpecifiedTradeSettlementHeaderMonetarySummation/GrandTotalAmount');
        Info.DuePayable := Doc.Text(s, 'SpecifiedTradeSettlementHeaderMonetarySummation/DuePayableAmount');
      end;
    eisynZUGFeRD1:
      begin
        Info.GuidelineID := Doc.Text(0, 'SpecifiedExchangedDocumentContext/GuidelineSpecifiedDocumentContextParameter/ID');
        Info.InvoiceNumber := Doc.Text(0, 'HeaderExchangedDocument/ID');
        Info.TypeCode := Doc.Text(0, 'HeaderExchangedDocument/TypeCode');
        Info.IssueDate := FormatDate102(Doc.Text(0, 'HeaderExchangedDocument/IssueDateTime/DateTimeString'));
        t := Doc.Path(0, 'SpecifiedSupplyChainTradeTransaction');
        Info.SellerName := Doc.Text(t, 'ApplicableSupplyChainTradeAgreement/SellerTradeParty/Name');
        Info.BuyerName := Doc.Text(t, 'ApplicableSupplyChainTradeAgreement/BuyerTradeParty/Name');
        s := Doc.Path(t, 'ApplicableSupplyChainTradeSettlement');
        Info.Currency := Doc.Text(s, 'InvoiceCurrencyCode');
        Info.GrandTotal := Doc.Text(s, 'SpecifiedTradeSettlementMonetarySummation/GrandTotalAmount');
        Info.DuePayable := Doc.Text(s, 'SpecifiedTradeSettlementMonetarySummation/DuePayableAmount');
      end;
    eisynUBLInvoice, eisynUBLCreditNote:
      begin
        Info.GuidelineID := Doc.Text(0, 'CustomizationID');
        Info.InvoiceNumber := Doc.Text(0, 'ID');
        Info.IssueDate := Doc.Text(0, 'IssueDate');

        if Info.Syntax = eisynUBLInvoice then begin
          Info.TypeCode := Doc.Text(0, 'InvoiceTypeCode');
        end else begin
          Info.TypeCode := Doc.Text(0, 'CreditNoteTypeCode');
        end;

        Info.Currency := Doc.Text(0, 'DocumentCurrencyCode');
        v := Doc.Text(0, 'AccountingSupplierParty/Party/PartyLegalEntity/RegistrationName');
        if v = '' then v := Doc.Text(0, 'AccountingSupplierParty/Party/PartyName/Name');
        Info.SellerName := v;
        v := Doc.Text(0, 'AccountingCustomerParty/Party/PartyLegalEntity/RegistrationName');
        if v = '' then v := Doc.Text(0, 'AccountingCustomerParty/Party/PartyName/Name');
        Info.BuyerName := v;
        Info.GrandTotal := Doc.Text(0, 'LegalMonetaryTotal/TaxInclusiveAmount');
        Info.DuePayable := Doc.Text(0, 'LegalMonetaryTotal/PayableAmount');
      end;
  end;

  Info.Profile := ProfileFromGuideline(Info.GuidelineID, Info.XRechnungVersion);
end;

procedure ReadXMP(const Data: TBytes; var Info: TEInvoiceInfo);
var
  doc: TXDoc;
  i, j: Integer;

  { urn:factur-x:pdfa:CrossIndustryDocument:invoice:1p0# and its ZUGFeRD 2.0
    and 1.0 forms; not other namespaces of the ZUGFeRD world (such as the
    additional data of the community, which has DocumentFileName as well) }
  function IsFxNS(const NS: string): Boolean;
  begin
    result := Pos('crossindustrydocument', LowerCase(NS)) > 0;
  end;

  procedure Take(const NS, Name, Value: string);
  begin
    if Value = '' then exit;

    if NS = NS_PDFAID then begin
      if Name = 'part' then Info.PDFAPart := Value
      else if Name = 'conformance' then Info.PDFAConformance := Value;
    end else if IsFxNS(NS) then begin
      if Name = 'DocumentType' then Info.XMPDocumentType := Value
      else if Name = 'DocumentFileName' then Info.XMPDocumentFileName := Value
      else if Name = 'Version' then Info.XMPVersion := Value
      else if Name = 'ConformanceLevel' then Info.XMPConformanceLevel := Value;
    end;
  end;

begin
  if not XmlParse(Data, doc) then exit;

  for i := 0 to doc.Count - 1 do begin
    if doc.Elems[i].FirstChild < 0 then begin
      Take(doc.Elems[i].NS, doc.Elems[i].Name, Trim(doc.Elems[i].Text));
    end;

    for j := 0 to High(doc.Elems[i].Attrs) do begin
      Take(doc.Elems[i].Attrs[j].NS, doc.Elems[i].Attrs[j].Name, Trim(doc.Elems[i].Attrs[j].Value));
    end;
  end;
end;

function IsPdfData(const Data: TBytes): Boolean;
begin
  result := FindAt(Data, IMin(Length(Data), 1024), 0, '%PDF-') >= 0;
end;

function IsXmlData(const Data: TBytes): Boolean;
var
  p: Integer;
begin
  result := false;
  if Length(Data) < 2 then exit;
  if ((Data[0] = $FF) and (Data[1] = $FE)) or ((Data[0] = $FE) and (Data[1] = $FF)) then exit(true);
  p := 0;
  if (Length(Data) >= 3) and (Data[0] = $EF) and (Data[1] = $BB) and (Data[2] = $BF) then p := 3;

  while (p < Length(Data)) and IsXmlWS(Data[p]) do begin
    Inc(p);
  end;

  result := (p < Length(Data)) and (Data[p] = Ord('<'));
end;

function KnownNameRank(const Name: string): Integer;
var
  i: Integer;
  s: string;
begin
  s := LowerCase(Name);

  for i := 0 to High(KnownInvoiceNames) do begin
    if s = KnownInvoiceNames[i] then exit(i);
  end;

  result := -1;
end;

{ Picks the invoice XML among the embedded files of a PDF. }
function FindInvoiceInPdf(var Pdf: TPdf; var Info: TEInvoiceInfo; out Xml: TBytes;
  var Msgs: TAbMessages): TAbResult;
var
  files: TPdfFiles;
  i, rank, bestRank, best: Integer;
  data, meta: TBytes;
  err: string;
  doc: TXDoc;
begin
  Xml := nil;
  files := Pdf.EmbeddedFiles;
  SetLength(Info.Attachments, Length(files));

  for i := 0 to High(files) do begin
    Info.Attachments[i].Name := files[i].Name;
    Info.Attachments[i].Description := files[i].Desc;
    Info.Attachments[i].MimeType := files[i].Mime;
    Info.Attachments[i].Relationship := files[i].Relationship;
    Info.Attachments[i].Size := files[i].Size;
    Info.Attachments[i].InAF := files[i].InAF;
  end;

  if Pdf.MetadataXML(meta) then begin
    ReadXMP(meta, Info);
  end;

  best := -1;
  bestRank := MaxInt;

  for i := 0 to High(files) do begin
    if files[i].Stream < 0 then continue;
    rank := KnownNameRank(files[i].Name);
    if rank < 0 then begin
      if (LowerCase(ExtractFileExt(files[i].Name)) = '.xml') or (Pos('xml', LowerCase(files[i].Mime)) > 0) then begin
        rank := 10;
      end else begin
        rank := 20;
      end;
    end;

    if rank >= bestRank then continue;

    if not Pdf.StreamData(files[i].Stream, data, err) then begin
      AddMsg(Msgs, abWarning, 'PDF-STREAM',
        Format('Attachment "%s" cannot be read: %s', [files[i].Name, err]));
      continue;
    end;

    if not IsXmlData(data) then continue;

    // files with a well-known name count even if broken; others must be an invoice
    if (rank >= 10) and (not XmlParse(data, doc) or (DetectSyntax(doc) = eisynUnknown)) then begin
      continue;
    end;

    best := i;
    bestRank := rank;
    Xml := data;
  end;

  if best < 0 then exit(abNoInvoice);
  Info.InvoiceFileName := files[best].Name;
  result := abOK;
end;

procedure CheckPdfInvoice(const Info: TEInvoiceInfo; var Msgs: TAbMessages);
var
  otherName: Boolean;
  i: Integer;
  rel, expected: string;
begin
  if Info.PDFAPart = '' then begin
    AddMsg(Msgs, abWarning, 'PDF-NO-PDFA',
      'No PDF/A identification in the XMP metadata (ZUGFeRD requires PDF/A-3)');
  end else if Info.PDFAPart <> '3' then begin
    AddMsg(Msgs, abWarning, 'PDF-PDFA-PART',
      Format('PDF/A-%s instead of PDF/A-3 (ZUGFeRD requires PDF/A-3)', [Info.PDFAPart]));
  end;

  if Info.XMPConformanceLevel = '' then begin
    AddMsg(Msgs, abWarning, 'ZF-XMP',
      'The XMP metadata contains no ZUGFeRD/Factur-X data');
  end else if (ProfileKey(Info.Profile) <> '') and
    (NormalizeLevel(Info.XMPConformanceLevel) <> ProfileKey(Info.Profile)) then
  begin
    AddMsg(Msgs, abWarning, 'ZF-XMP-PROFILE',
      Format('Profile in the XMP metadata (%s) does not match the invoice profile (%s)',
      [Info.XMPConformanceLevel, TAbdecker.ProfileName(Info.Profile)]));
  end;

  otherName := (Info.XMPDocumentFileName <> '') and
    not SameText(Info.XMPDocumentFileName, Info.InvoiceFileName);

  if otherName then begin
    AddMsg(Msgs, abWarning, 'ZF-XMP-FILENAME',
      Format('File name in the XMP metadata (%s) differs from the embedded name (%s)',
      [Info.XMPDocumentFileName, Info.InvoiceFileName]));
  end;

  for i := 0 to High(Info.Attachments) do begin
    if Info.Attachments[i].Name = Info.InvoiceFileName then begin
      if not Info.Attachments[i].InAF then begin
        AddMsg(Msgs, abWarning, 'ZF-AF',
          'The invoice file is not listed in the /AF array of the PDF (PDF/A-3)');
      end;

      rel := Info.Attachments[i].Relationship;
      if (rel <> 'Alternative') and (rel <> 'Data') and (rel <> 'Source') then begin
        AddMsg(Msgs, abInfo, 'ZF-AFREL',
          Format('Unusual AFRelationship "%s" (expected: Alternative, Data or Source)', [rel]));
      end;

      break;
    end;
  end;

  if Info.Syntax = eisynZUGFeRD1 then begin
    expected := 'zugferd-invoice.xml';
  end else if Info.Profile = eiprofXRechnung then begin
    expected := 'xrechnung.xml';
  end else begin
    expected := 'factur-x.xml';
  end;

  if KnownNameRank(Info.InvoiceFileName) < 0 then begin
    AddMsg(Msgs, abInfo, 'ZF-FILENAME',
      Format('Unusual file name "%s" for the invoice (usual: %s)',
      [Info.InvoiceFileName, expected]));
  end;
end;

{ Core analysis shared by Info and ExtractXML. Xml receives the invoice
  bytes (for PDFs: the embedded file, unchanged). }
function Analyze(const Data: TBytes; var Info: TEInvoiceInfo; out Xml: TBytes;
  var Doc: TXDoc; var Msgs: TAbMessages): TAbResult;
var
  pdf: TPdf;
begin
  Xml := nil;

  if IsPdfData(Data) then begin
    Info.Container := eicontPDF;

    if not pdf.Open(Data, Msgs) then begin
      AddMsg(Msgs, abError, 'PDF-BROKEN', 'The PDF structure cannot be read');
      exit(abBrokenPDF);
    end;

    Info.PDFVersion := pdf.Version;

    if pdf.Encrypted then begin
      AddMsg(Msgs, abError, 'PDF-ENCRYPTED',
        'The PDF is encrypted. Encrypted PDFs are not supported.');
      exit(abEncrypted);
    end;

    result := FindInvoiceInPdf(pdf, Info, Xml, Msgs);
    if (result = abNoInvoice) and not pdf.Rebuilt and (pdf.LoadFailures > 0) then begin
      // the xref table points to unreadable objects - try again the hard way
      pdf.Rebuild;

      if FindInvoiceInPdf(pdf, Info, Xml, Msgs) = abOK then begin
        result := abOK;
        AddMsg(Msgs, abWarning, 'PDF-XREF',
          'The PDF cross-reference table is broken, the structure was reconstructed');
      end;
    end;

    if result <> abOK then begin
      AddMsg(Msgs, abInfo, 'PDF-NO-INVOICE', 'The PDF contains no embedded e-invoice');
      exit;
    end;
  end else if IsXmlData(Data) then begin
    Info.Container := eicontXML;
    Xml := Data;
  end else begin
    AddMsg(Msgs, abError, 'FORMAT', 'The file is neither PDF nor XML');
    exit(abUnknownFormat);
  end;

  if not XmlParse(Xml, Doc) then begin
    AddMsg(Msgs, abError, 'XML-SYNTAX', 'Broken XML: ' + Doc.Error);
    exit(abBrokenXML);
  end;

  Info.Syntax := DetectSyntax(Doc);
  if Info.Syntax = eisynUnknown then begin
    AddMsg(Msgs, abError, 'XML-UNKNOWN',
      Format('Unknown XML format (root element "%s", namespace "%s")',
      [Doc.Elems[0].Name, Doc.Elems[0].NS]));
    exit(abUnknownFormat);
  end;

  FillFacts(Doc, Info);

  if Info.Profile = eiprofUnknown then begin
    AddMsg(Msgs, abWarning, 'PROFILE-UNKNOWN',
      Format('Profile not recognized (identifier "%s")', [Info.GuidelineID]));
  end else if Info.Profile in [eiprofMinimum, eiprofBasicWL] then begin
    AddMsg(Msgs, abWarning, 'ZF-NOT-EINVOICE',
      Format('Profile %s does not count as an e-invoice under §14 UStG (accounting aid only)',
      [TAbdecker.ProfileName(Info.Profile)]));
  end;

  if Info.Container = eicontPDF then begin
    CheckPdfInvoice(Info, Msgs);
  end;

  result := abOK;
end;

{ ===========================================================================
  Invoice model: the reader shared by abdecker.cii and abdecker.ubl
  =========================================================================== }

procedure TModelReader.Init;
var
  i: Integer;
begin
  SetLength(Used, Doc.Count);

  for i := 0 to High(Used) do begin
    Used[i] := false;
  end;

  if Doc.Count > 0 then Used[0] := true;
  Msgs := nil;
end;

function TModelReader.El(p: Integer; const APath: string): Integer;
begin
  if p < 0 then exit(-1);
  result := Doc.Path(p, APath);
  if result >= 0 then Used[result] := true;
end;

function TModelReader.First(p: Integer; const Name: string): Integer;
begin
  result := Doc.Child(p, Name);
  if result >= 0 then Used[result] := true;
end;

function TModelReader.Next(e: Integer): Integer;
var
  n: string;
begin
  n := Doc.Elems[e].Name;
  result := Doc.Elems[e].Next;
  while (result >= 0) and (Doc.Elems[result].Name <> n) do begin
    result := Doc.Elems[result].Next;
  end;

  if result >= 0 then Used[result] := true;
end;

function TModelReader.TextOf(e: Integer): string;
begin
  if e < 0 then exit('');
  Used[e] := true;
  result := Trim(Doc.Elems[e].Text);
end;

function TModelReader.Str(p: Integer; const APath: string): string;
begin
  result := TextOf(El(p, APath));
end;

function TModelReader.RawStr(p: Integer; const APath: string): string;
var
  e: Integer;
begin
  e := El(p, APath);
  if e >= 0 then begin
    result := Doc.Elems[e].Text;
  end else begin
    result := '';
  end;
end;

procedure TModelReader.Skip(p: Integer; const APath: string);
begin
  El(p, APath);
end;

function TModelReader.Attr(e: Integer; const Name: string): string;
begin
  result := Doc.Attr(e, Name);
end;

function TModelReader.NumOf(e: Integer; const BT: string): TAbDecimal;
begin
  result := TAbDecimal.Parse(TextOf(e));
  if result.Present and not result.Valid then begin
    AddMsg(Msgs, abWarning, 'NUMBER', Format('%s: "%s" is not a valid number', [BT, result.Text]));
  end;
end;

function TModelReader.Num(p: Integer; const APath, BT: string): TAbDecimal;
begin
  result := NumOf(El(p, APath), BT);
end;

function TModelReader.DateStr(p: Integer; const APath: string): string;
begin
  result := FormatDate102(Str(p, APath));
end;

function TModelReader.IdentOf(e: Integer; const SchemeAttr: string): TEInvoiceID;
begin
  result.Value := TextOf(e);
  result.Scheme := Attr(e, SchemeAttr);
end;

function TModelReader.Ident(p: Integer; const APath: string): TEInvoiceID;
begin
  result := IdentOf(El(p, APath), 'schemeID');
end;

function TModelReader.Unmapped: TAbStrings;
var
  i, p, n: Integer;
  path, v: string;
  u: UnicodeString;
begin
  result := nil;
  n := 0;

  for i := 1 to Doc.Count - 1 do begin
    if Used[i] or (Doc.Elems[i].FirstChild >= 0) then continue;
    v := Trim(Doc.Elems[i].Text);
    if v = '' then continue;
    path := Doc.Elems[i].Name;
    p := Doc.Elems[i].Parent;
    while p > 0 do begin
      path := Doc.Elems[p].Name + '/' + path;
      p := Doc.Elems[p].Parent;
    end;

    // shortened by UTF-16 units under both compilers (FPC: string holds UTF-8)
    u := UnicodeString(v);
    if Length(u) > 80 then v := string(Copy(u, 1, 77)) + '...';
    SetLength(result, n + 1);
    result[n] := path + ' = ' + v;
    Inc(n);
  end;
end;

procedure AddID(var IDs: TEInvoiceIDs; const ID: TEInvoiceID);
begin
  if ID.Value = '' then exit;
  SetLength(IDs, Length(IDs) + 1);
  IDs[High(IDs)] := ID;
end;

procedure AddAC(var List: TEInvoiceAllowanceCharges; const AC: TEInvoiceAllowanceCharge);
begin
  SetLength(List, Length(List) + 1);
  List[High(List)] := AC;
end;

procedure AppendText(var s: string; const t: string);
begin
  if t = '' then exit;
  if s <> '' then s := s + #10;
  s := s + t;
end;

procedure ReadModel(const Doc: TXDoc; var Inv: TEInvoice; var Msgs: TAbMessages);
var
  r: TModelReader;
  i: Integer;
begin
  r.Doc := Doc;
  r.Init;

  case Inv.Info.Syntax of
    eisynCII, eisynZUGFeRD1: ParseCii(r, Inv.Info.Syntax, Inv);
    eisynUBLInvoice: ParseUbl(r, false, Inv);
    eisynUBLCreditNote: ParseUbl(r, true, Inv);
  end;

  Inv.Unmapped := r.Unmapped;

  for i := 0 to High(r.Msgs) do begin
    AddMsg(Msgs, r.Msgs[i].Severity, r.Msgs[i].Code, r.Msgs[i].Text);
  end;
end;

function SafeAnalyze(const Data: TBytes; var Info: TEInvoiceInfo; out Xml: TBytes;
  var Doc: TXDoc; var Msgs: TAbMessages): TAbResult;
begin
  Xml := nil;

  try
    result := Analyze(Data, Info, Xml, Doc, Msgs);
  except
    on e: Exception do begin
      AddMsg(Msgs, abError, 'INTERNAL', 'Internal error: ' + e.Message);
      result := abInternalError;
    end;
  end;
end;

end.
