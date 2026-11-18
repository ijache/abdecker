{ SPDX-License-Identifier: MIT
  Copyright (c) 2026 Ingo Jache }

unit abdecker.attach;

{ abdecker - attachments (internal): add supporting documents (BG-24) to an
  invoice XML, and read all files that come with an invoice (embedded files
  of a PDF, BG-24 documents). Not part of the public API: use the unit
  abdecker.

  The XML is not rebuilt: the new elements are inserted as text at the place
  the schema demands, everything else stays byte for byte.
    CII  ram:AdditionalReferencedDocument in ram:ApplicableHeaderTradeAgreement
         (IssuerAssignedID, TypeCode 916, Name, AttachmentBinaryObject)
    UBL  cac:AdditionalDocumentReference below the root
         (cbc:ID, cbc:DocumentDescription, cac:Attachment) }

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

{ MIME code (BT-125-1) for a file name, '' if the type is not allowed.
  EN 16931 allows PDF, PNG, JPEG, CSV, XLSX and ODS. }
function MimeForFileName(const FileName: string): string;
function AllowedMime(const Mime: string): Boolean;
function AllowedMimeList: string;

{ Inserts the documents (ID, FileName, MimeType and Content set). Xml must
  be UTF-8 and of the given syntax. }
function InsertDocuments(const Xml: TBytes; Syntax: TEInvoiceSyntax; const Docs: TEInvoiceDocuments;
  out OutXml: TBytes; var Msgs: TAbMessages): TAbResult;

{ Embedded files of a PDF and BG-24 documents of the invoice, with content
  (TAbdecker.AttachmentsFromBytes). }
function ReadAttachments(const Data: TBytes; out Files: TEInvoiceFiles; var Msgs: TAbMessages): TAbResult;

implementation

uses
  abdecker.util, abdecker.xml, abdecker.pdf, abdecker.read;

const
  NS_RAM = 'urn:un:unece:uncefact:data:standard:ReusableAggregateBusinessInformationEntity:100';
  NS_CAC = 'urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2';
  NS_CBC = 'urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2';

  MimeExt: array[0..6] of string = ('.pdf', '.png', '.jpg', '.jpeg', '.csv', '.xlsx', '.ods');
  MimeCode: array[0..6] of string = ('application/pdf', 'image/png', 'image/jpeg', 'image/jpeg',
    'text/csv', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'application/vnd.oasis.opendocument.spreadsheet');

  { elements that follow the documents in the schema, if there are none yet }
  CiiAfter: array[0..4] of string = ('RequisitionerReferencedDocument', 'BuyerAgentTradeParty',
    'PurchaseConditionsReferencedDocument', 'SpecifiedProcuringProject',
    'UltimateCustomerOrderReferencedDocument');
  UblInvoiceAfter: array[0..2] of string = ('ProjectReference', 'Signature', 'AccountingSupplierParty');
  UblCreditNoteAfter: array[0..3] of string = ('StatementDocumentReference', 'OriginatorDocumentReference',
    'Signature', 'AccountingSupplierParty');

function MimeForFileName(const FileName: string): string;
var
  i: Integer;
  ext: string;
begin
  ext := LowerCase(ExtractFileExt(FileName));

  for i := 0 to High(MimeExt) do begin
    if MimeExt[i] = ext then exit(MimeCode[i]);
  end;

  result := '';
end;

function AllowedMime(const Mime: string): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(MimeCode) do begin
    if MimeCode[i] = Mime then exit(true);
  end;

  result := false;
end;

function AllowedMimeList: string;
var
  i: Integer;
begin
  result := '';

  for i := 0 to High(MimeExt) do begin
    if i > 0 then result := result + ', ';
    result := result + Copy(MimeExt[i], 2, MaxInt);
  end;
end;

function EscText(const s: string): string;
begin
  result := StringReplace(s, '&', '&amp;', [rfReplaceAll]);
  result := StringReplace(result, '<', '&lt;', [rfReplaceAll]);
  result := StringReplace(result, '>', '&gt;', [rfReplaceAll]);
end;

function EscAttr(const s: string): string;
begin
  result := StringReplace(EscText(s), '"', '&quot;', [rfReplaceAll]);
end;

{ Prefix declared on the root element for a namespace ('' if none) }
function RootPrefix(const Doc: TXDoc; const NS: string): string;
var
  i: Integer;
begin
  for i := 0 to High(Doc.RootDecls) do begin
    if (Doc.RootDecls[i].Value = NS) and (Doc.RootDecls[i].Name <> '') then begin
      exit(Doc.RootDecls[i].Name);
    end;
  end;

  result := '';
end;

function InList(const s: string; const List: array of string): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(List) do begin
    if List[i] = s then exit(true);
  end;

  result := false;
end;

{ The child of Parent after which the documents go: the last existing
  document, else the element before the first one that must follow. }
function InsertAfter(const Doc: TXDoc; Parent: Integer; const Name: string;
  const Following: array of string): Integer;
var
  e, prev, last: Integer;
begin
  last := -1;
  e := Doc.Elems[Parent].FirstChild;
  while e >= 0 do begin
    if Doc.Elems[e].Name = Name then last := e;
    e := Doc.Elems[e].Next;
  end;

  if last >= 0 then exit(last);
  prev := -1;
  e := Doc.Elems[Parent].FirstChild;
  while e >= 0 do begin
    if InList(Doc.Elems[e].Name, Following) then exit(prev);
    prev := e;
    e := Doc.Elems[e].Next;
  end;

  result := prev;
end;

{ Whitespace in front of position Pos on its line; False if other text
  precedes it on that line (no line structure to follow) }
function LineIndent(const b: TBytes; Pos: Integer; out Indent: string; out CRLF: Boolean): Boolean;
var
  k: Integer;
begin
  k := Pos - 1;
  while (k >= 0) and ((b[k] = $20) or (b[k] = $09)) do begin
    Dec(k);
  end;

  result := (k >= 0) and (b[k] = $0A);
  CRLF := result and (k > 0) and (b[k - 1] = $0D);

  if result then begin
    Indent := Utf8Str(b, k + 1, Pos - k - 1);
  end else begin
    Indent := '';
  end;
end;

function InsertDocuments(const Xml: TBytes; Syntax: TEInvoiceSyntax; const Docs: TEInvoiceDocuments;
  out OutXml: TBytes; var Msgs: TAbMessages): TAbResult;
var
  doc: TXDoc;
  parent, after, i, cut: Integer;
  ram, cac, cbc, decl, nl, ind, parInd, step, frag: string;
  lines, crlf, dummy, deeperIndent: Boolean;
  ins: TBytes;

  function Line(Level: Integer; const s: string): string;
  var
    k: Integer;
  begin
    result := nl + ind;

    for k := 1 to Level do begin
      result := result + step;
    end;

    result := result + s;
  end;

begin
  OutXml := nil;

  if not XmlParse(Xml, doc) then begin
    AddMsg(Msgs, abError, 'XML-SYNTAX', 'Broken XML: ' + doc.Error);
    exit(abBrokenXML);
  end;

  // where the documents go
  decl := '';

  if Syntax = eisynCII then begin
    parent := doc.Path(0, 'SupplyChainTradeTransaction/ApplicableHeaderTradeAgreement');
    if parent < 0 then begin
      AddMsg(Msgs, abError, 'ATTACH-POSITION', 'The invoice has no ApplicableHeaderTradeAgreement');
      exit(abUnsupported);
    end;

    after := InsertAfter(doc, parent, 'AdditionalReferencedDocument', CiiAfter);
    ram := RootPrefix(doc, NS_RAM);
    if ram = '' then begin
      ram := 'ram';
      decl := ' xmlns:ram="' + NS_RAM + '"';
    end;
  end else begin
    parent := 0;

    if Syntax = eisynUBLCreditNote then begin
      after := InsertAfter(doc, parent, 'AdditionalDocumentReference', UblCreditNoteAfter);
    end else begin
      after := InsertAfter(doc, parent, 'AdditionalDocumentReference', UblInvoiceAfter);
    end;

    cac := RootPrefix(doc, NS_CAC);
    if cac = '' then begin
      cac := 'cac';
      decl := ' xmlns:cac="' + NS_CAC + '"';
    end;

    cbc := RootPrefix(doc, NS_CBC);
    if cbc = '' then begin
      cbc := 'cbc';
      decl := decl + ' xmlns:cbc="' + NS_CBC + '"';
    end;
  end;

  if after < 0 then begin
    AddMsg(Msgs, abError, 'ATTACH-POSITION', 'No place for the attachments found in the invoice');
    exit(abUnsupported);
  end;

  // follow the line structure of the file: same indentation as the sibling
  lines := LineIndent(Xml, doc.Elems[after].StartPos, ind, crlf);
  if lines then begin
    if crlf then begin
      nl := #13#10;
    end else begin
      nl := #10;
    end;

    step := '  ';
    deeperIndent := LineIndent(Xml, doc.Elems[parent].StartPos, parInd, dummy) and (Length(ind) > Length(parInd)) and
      (Copy(ind, 1, Length(parInd)) = parInd);
    if deeperIndent then step := Copy(ind, Length(parInd) + 1, MaxInt);
  end else begin
    nl := '';
    ind := '';
    step := '';
  end;

  frag := '';

  for i := 0 to High(Docs) do begin
    if Syntax = eisynCII then begin
      frag := frag +
        Line(0, '<' + ram + ':AdditionalReferencedDocument' + decl + '>') +
        Line(1, '<' + ram + ':IssuerAssignedID>' + EscText(Docs[i].ID) + '</' + ram + ':IssuerAssignedID>') +
        Line(1, '<' + ram + ':TypeCode>916</' + ram + ':TypeCode>');

      if Docs[i].Description <> '' then begin
        frag := frag + Line(1, '<' + ram + ':Name>' + EscText(Docs[i].Description) + '</' + ram + ':Name>');
      end;

      frag := frag +
        Line(1, '<' + ram + ':AttachmentBinaryObject mimeCode="' + EscAttr(Docs[i].MimeType) +
          '" filename="' + EscAttr(Docs[i].FileName) + '">' + EncodeBase64(Docs[i].Content) +
          '</' + ram + ':AttachmentBinaryObject>') +
        Line(0, '</' + ram + ':AdditionalReferencedDocument>');
    end else begin
      frag := frag +
        Line(0, '<' + cac + ':AdditionalDocumentReference' + decl + '>') +
        Line(1, '<' + cbc + ':ID>' + EscText(Docs[i].ID) + '</' + cbc + ':ID>');

      if Docs[i].Description <> '' then begin
        frag := frag + Line(1, '<' + cbc + ':DocumentDescription>' + EscText(Docs[i].Description) +
          '</' + cbc + ':DocumentDescription>');
      end;

      frag := frag +
        Line(1, '<' + cac + ':Attachment>') +
        Line(2, '<' + cbc + ':EmbeddedDocumentBinaryObject mimeCode="' + EscAttr(Docs[i].MimeType) +
          '" filename="' + EscAttr(Docs[i].FileName) + '">' + EncodeBase64(Docs[i].Content) +
          '</' + cbc + ':EmbeddedDocumentBinaryObject>') +
        Line(1, '</' + cac + ':Attachment>') +
        Line(0, '</' + cac + ':AdditionalDocumentReference>');
    end;
  end;

  ins := Utf8Bytes(frag);
  cut := doc.Elems[after].EndPos;
  SetLength(OutXml, Length(Xml) + Length(ins));

  if cut > 0 then begin
    Move(Xml[0], OutXml[0], cut);
  end;

  if Length(ins) > 0 then begin
    Move(ins[0], OutXml[cut], Length(ins));
  end;

  if Length(Xml) > cut then begin
    Move(Xml[cut], OutXml[cut + Length(ins)], Length(Xml) - cut);
  end;

  result := abOK;
end;

{ ===========================================================================
  Reading attachments
  =========================================================================== }

procedure AddDocuments(const Inv: TEInvoice; var Files: TEInvoiceFiles);
var
  i, n: Integer;
  d: TEInvoiceDocument;
begin
  for i := 0 to High(Inv.Documents) do begin
    d := Inv.Documents[i];
    // BG-24 also lists plain references without file (only ID/description)
    if (Length(d.Content) = 0) and (d.URI = '') and (d.FileName = '') then continue;
    n := Length(Files);
    SetLength(Files, n + 1);
    Files[n] := Default(TEInvoiceFile);
    Files[n].Source := eisrcInvoice;
    Files[n].Name := d.FileName;
    Files[n].Description := d.Description;
    Files[n].MimeType := d.MimeType;
    Files[n].ID := d.ID;
    Files[n].URI := d.URI;
    Files[n].Content := d.Content;
  end;
end;

function ReadAttachments(const Data: TBytes; out Files: TEInvoiceFiles; var Msgs: TAbMessages): TAbResult;
var
  pdf: TPdf;
  pf: TPdfFiles;
  inv: TEInvoice;
  loadMsgs: TAbMessages;
  r: TAbResult;
  i: Integer;
  err: string;
begin
  Files := nil;

  if not IsPdfData(Data) then begin
    // XML (or anything else): the invoice must be readable
    result := TAbdecker.LoadFromBytes(Data, inv, loadMsgs);
    if result <> abOK then begin
      Msgs := Concat(Msgs, loadMsgs);
      exit;
    end;

    AddDocuments(inv, Files);
    exit(abOK);
  end;

  if not pdf.Open(Data, Msgs) then begin
    AddMsg(Msgs, abError, 'PDF-BROKEN', 'The PDF structure cannot be read');
    exit(abBrokenPDF);
  end;

  if pdf.Encrypted then begin
    AddMsg(Msgs, abError, 'PDF-ENCRYPTED', 'The PDF is encrypted. Encrypted PDFs are not supported.');
    exit(abEncrypted);
  end;

  pf := pdf.EmbeddedFiles;
  if (Length(pf) = 0) and not pdf.Rebuilt and (pdf.LoadFailures > 0) then begin
    pdf.Rebuild;
    pf := pdf.EmbeddedFiles;
  end;

  SetLength(Files, Length(pf));

  for i := 0 to High(pf) do begin
    Files[i] := Default(TEInvoiceFile);
    Files[i].Source := eisrcPDF;
    Files[i].Name := pf[i].Name;
    Files[i].Description := pf[i].Desc;
    Files[i].MimeType := pf[i].Mime;
    Files[i].Relationship := pf[i].Relationship;

    if (pf[i].Stream < 0) or not pdf.StreamData(pf[i].Stream, Files[i].Content, err) then begin
      Files[i].Content := nil;
      AddMsg(Msgs, abWarning, 'PDF-STREAM', Format('Attachment "%s" cannot be read: %s', [pf[i].Name, err]));
    end;
  end;

  // the invoice inside: mark its file, add its BG-24 documents
  r := TAbdecker.LoadFromBytes(Data, inv, loadMsgs);
  if r = abOK then begin
    for i := 0 to High(Files) do begin
      if Files[i].Name = inv.Info.InvoiceFileName then begin
        Files[i].IsInvoice := true;
        break;
      end;
    end;

    AddDocuments(inv, Files);
  end else if r <> abNoInvoice then begin
    AddMsg(Msgs, abWarning, 'ATTACH-INVOICE',
      'The invoice XML in the PDF cannot be read: its attachments (BG-24) are missing');
  end;

  result := abOK;
end;

end.
