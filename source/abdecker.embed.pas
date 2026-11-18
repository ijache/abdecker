{ SPDX-License-Identifier: MIT
  Copyright (c) 2026 Ingo Jache }

unit abdecker.embed;

{ abdecker - embed an invoice XML into an existing PDF, or remove it (internal).
  Not part of the public API: use the unit abdecker.

  The original bytes stay untouched; an incremental update is appended:
    - embedded file stream (FlateDecode) with the XML, unchanged
    - file specification with /AFRelationship
    - new version of the catalog: /Names /EmbeddedFiles, /AF, /Metadata
    - XMP metadata: the existing packet plus the Factur-X schema and its
      PDF/A extension schema description; pdfaid:part 1/2 becomes 3
    - cross-reference section in the form of the original (table or stream)
  No PDF/A conversion: fonts, colours and the output intent are not touched.

  Strip works the same way: a new version of the catalog without the invoice
  in /Names /EmbeddedFiles and /AF, and new XMP metadata without the
  ZUGFeRD/Factur-X properties. The data of the embedded file, now no longer
  referenced, is overwritten in place with the same length (Flate: valid
  zlib data of zeros), so offsets and cross-references stay valid. Not for
  signed PDFs and not if other parts of the document still refer to it. }

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

{ PdfAPart: pdfaid:part of the input ('' if none). Level: fx:ConformanceLevel. }
function EmbedInvoice(const PdfData, Xml: TBytes; const XmlName, Level, Relationship,
  PdfAPart: string; out OutPdf: TBytes; var Msgs: TAbMessages): TAbResult;

{ Removes the embedded file XmlName from the name tree and /AF of the
  catalog, and the ZUGFeRD/Factur-X properties from the XMP metadata;
  overwrites the file data where that is safe. }
function StripInvoice(const PdfData: TBytes; const XmlName: string; out OutPdf: TBytes;
  var Msgs: TAbMessages): TAbResult;

implementation

uses
  abdecker.util, abdecker.pdf, abdecker.zlib;

const
  NS_RDF = 'http://www.w3.org/1999/02/22-rdf-syntax-ns#';
  NS_PDFAID = 'http://www.aiim.org/pdfa/ns/id/';
  NS_PDFA_EXT = 'http://www.aiim.org/pdfa/ns/extension/';
  NS_FX = 'urn:factur-x:pdfa:CrossIndustryDocument:invoice:1p0#';
  NS_PDF = 'http://ns.adobe.com/pdf/1.3/';

{ ===========================================================================
  XMP
  =========================================================================== }

function XmlEsc(const s: string): string;
begin
  result := StringReplace(s, '&', '&amp;', [rfReplaceAll]);
  result := StringReplace(result, '<', '&lt;', [rfReplaceAll]);
  result := StringReplace(result, '>', '&gt;', [rfReplaceAll]);
end;

{ Prefix bound to a namespace URI in the XMP text ('' if not declared) }
function PrefixOf(const Xmp, NS: string): string;
var
  p, q: Integer;
begin
  result := '';
  p := Pos('"' + NS + '"', Xmp);
  if p = 0 then p := Pos('''' + NS + '''', Xmp);
  if p = 0 then exit;
  // walk back over '=' to 'xmlns:prefix'
  q := p - 1;
  while (q > 0) and (Xmp[q] <= ' ') do begin
    Dec(q);
  end;

  if (q < 1) or (Xmp[q] <> '=') then exit;
  Dec(q);

  while (q > 0) and (Xmp[q] <= ' ') do begin
    Dec(q);
  end;

  p := q;

  while (q > 0) and (Xmp[q] > ' ') and (Xmp[q] <> ':') do begin
    Dec(q);
  end;

  if (q < 6) or (Xmp[q] <> ':') or (Copy(Xmp, q - 5, 5) <> 'xmlns') then exit;
  result := Copy(Xmp, q + 1, p - q);
end;

function FxDescription(const Rdf, FileName, Level: string): string;
begin
  result :=
    '<' + Rdf + ':Description ' + Rdf + ':about="" xmlns:fx="' + NS_FX + '">'#10 +
    '  <fx:DocumentType>INVOICE</fx:DocumentType>'#10 +
    '  <fx:DocumentFileName>' + XmlEsc(FileName) + '</fx:DocumentFileName>'#10 +
    '  <fx:Version>1.0</fx:Version>'#10 +
    '  <fx:ConformanceLevel>' + XmlEsc(Level) + '</fx:ConformanceLevel>'#10 +
    '</' + Rdf + ':Description>'#10;
end;

{ Description of the Factur-X schema, as required for PDF/A extension schemas }
function FxSchemaLi(const Rdf: string): string;

  function Prop(const Name, Desc: string): string;
  begin
    result :=
      '      <' + Rdf + ':li ' + Rdf + ':parseType="Resource">'#10 +
      '        <pdfaProperty:name>' + Name + '</pdfaProperty:name>'#10 +
      '        <pdfaProperty:valueType>Text</pdfaProperty:valueType>'#10 +
      '        <pdfaProperty:category>external</pdfaProperty:category>'#10 +
      '        <pdfaProperty:description>' + Desc + '</pdfaProperty:description>'#10 +
      '      </' + Rdf + ':li>'#10;
  end;

begin
  result :=
    '<' + Rdf + ':li ' + Rdf + ':parseType="Resource"' +
    ' xmlns:pdfaSchema="http://www.aiim.org/pdfa/ns/schema#"' +
    ' xmlns:pdfaProperty="http://www.aiim.org/pdfa/ns/property#">'#10 +
    '  <pdfaSchema:schema>Factur-X PDFA Extension Schema</pdfaSchema:schema>'#10 +
    '  <pdfaSchema:namespaceURI>' + NS_FX + '</pdfaSchema:namespaceURI>'#10 +
    '  <pdfaSchema:prefix>fx</pdfaSchema:prefix>'#10 +
    '  <pdfaSchema:property>'#10 +
    '    <' + Rdf + ':Seq>'#10 +
    Prop('DocumentFileName', 'The name of the embedded XML document') +
    Prop('DocumentType', 'The type of the hybrid document in capital letters, e.g. INVOICE or ORDER') +
    Prop('Version', 'The actual version of the standard applying to the embedded XML document') +
    Prop('ConformanceLevel', 'The conformance level of the embedded XML document') +
    '    </' + Rdf + ':Seq>'#10 +
    '  </pdfaSchema:property>'#10 +
    '</' + Rdf + ':li>'#10;
end;

function ExtensionDescription(const Rdf: string): string;
begin
  result :=
    '<' + Rdf + ':Description ' + Rdf + ':about="" xmlns:pdfaExtension="' + NS_PDFA_EXT + '">'#10 +
    '<pdfaExtension:schemas>'#10 +
    '<' + Rdf + ':Bag>'#10 +
    FxSchemaLi(Rdf) +
    '</' + Rdf + ':Bag>'#10 +
    '</pdfaExtension:schemas>'#10 +
    '</' + Rdf + ':Description>'#10;
end;

function NewXmp(const FileName, Level: string): string;
begin
  result :=
    '<?xpacket begin="' + #$FEFF + '" id="W5M0MpCehiHzreSzNTczkc9d"?>'#10 +
    '<x:xmpmeta xmlns:x="adobe:ns:meta/">'#10 +
    '<rdf:RDF xmlns:rdf="' + NS_RDF + '">'#10 +
    FxDescription('rdf', FileName, Level) +
    ExtensionDescription('rdf') +
    '</rdf:RDF>'#10 +
    '</x:xmpmeta>'#10 +
    '<?xpacket end="w"?>';
end;

{ Sets pdfaid:part to 3, as element or attribute. False if not found. }
function SetPdfAPart3(var Xmp: string): Boolean;
var
  p, i, q: Integer;
  pre, tag: string;
begin
  result := false;
  pre := PrefixOf(Xmp, NS_PDFAID);
  if pre = '' then exit;
  tag := '<' + pre + ':part>';
  p := Pos(tag, Xmp);
  if p > 0 then begin
    i := p + Length(tag);
    q := Pos('</' + pre + ':part>', Copy(Xmp, i, MaxInt));
    if q = 0 then exit;
    Xmp := Copy(Xmp, 1, i - 1) + '3' + Copy(Xmp, i + q - 1, MaxInt);
    exit(true);
  end;

  tag := pre + ':part=';
  p := Pos(tag, Xmp);
  if p > 0 then begin
    i := p + Length(tag);
    if (i <= Length(Xmp)) and ((Xmp[i] = '"') or (Xmp[i] = '''')) then begin
      q := i + 1;
      while (q <= Length(Xmp)) and (Xmp[q] <> Xmp[i]) do begin
        Inc(q);
      end;

      Xmp := Copy(Xmp, 1, i) + '3' + Copy(Xmp, q, MaxInt);
      exit(true);
    end;
  end;
end;

{ Replaces the value of an existing property (element or attribute form) }
function ReplaceProp(var Xmp: string; const Pre, Prop, Value: string): Boolean;
var
  p, i, q: Integer;
  tag: string;
begin
  result := false;
  tag := '<' + Pre + ':' + Prop + '>';
  p := Pos(tag, Xmp);
  if p > 0 then begin
    i := p + Length(tag);
    q := Pos('</' + Pre + ':' + Prop + '>', Copy(Xmp, i, MaxInt));
    if q > 0 then begin
      Xmp := Copy(Xmp, 1, i - 1) + XmlEsc(Value) + Copy(Xmp, i + q - 1, MaxInt);
      exit(true);
    end;
  end;

  tag := Pre + ':' + Prop + '=';
  p := Pos(tag, Xmp);
  if p > 0 then begin
    i := p + Length(tag);
    if (i <= Length(Xmp)) and ((Xmp[i] = '"') or (Xmp[i] = '''')) then begin
      q := i + 1;
      while (q <= Length(Xmp)) and (Xmp[q] <> Xmp[i]) do begin
        Inc(q);
      end;

      Xmp := Copy(Xmp, 1, i) + XmlEsc(Value) + Copy(Xmp, q, MaxInt);
      exit(true);
    end;
  end;
end;

{ Adds the Factur-X properties and the extension schema to an existing packet.
  If the PDF was ZUGFeRD before, the Factur-X properties exist already: they
  are updated instead of adding a second set; only what is missing is added. }
function MergeXmp(const Old, FileName, Level: string; var Msgs: TAbMessages; out Xmp: string): Boolean;
var
  notReplaced: Boolean;
  rdf, ext, tag, fxPre, desc, li: string;
  p, q, k: Integer;
begin
  result := false;
  Xmp := Old;
  rdf := PrefixOf(Xmp, NS_RDF);
  if rdf = '' then exit;
  desc := FxDescription(rdf, FileName, Level);
  fxPre := PrefixOf(Xmp, NS_FX);
  if fxPre <> '' then begin
    notReplaced := not (ReplaceProp(Xmp, fxPre, 'DocumentType', 'INVOICE') and
      ReplaceProp(Xmp, fxPre, 'DocumentFileName', FileName) and
      ReplaceProp(Xmp, fxPre, 'Version', '1.0') and
      ReplaceProp(Xmp, fxPre, 'ConformanceLevel', Level));

    if notReplaced then begin
      AddMsg(Msgs, abWarning, 'EMBED-XMP',
        'The existing Factur-X data in the XMP is incomplete and was not kept');
      exit;
    end;

    desc := '';
  end;
  // the extension schema may describe fx already
  li := FxSchemaLi(rdf);
  if Pos('>' + NS_FX + '<', Xmp) > 0 then li := '';
  if (desc = '') and (li = '') then exit(true);
  p := 0;
  tag := '</' + rdf + ':RDF>';
  q := Pos(tag, Xmp);
  while q > 0 do begin
    p := p + q;
    q := Pos(tag, Copy(Xmp, p + 1, MaxInt));
  end;

  if p = 0 then exit;

  // the extension schema list may exist already: add our schema to its bag
  if li <> '' then begin
    ext := PrefixOf(Xmp, NS_PDFA_EXT);
    q := 0;
    if ext <> '' then q := Pos('<' + ext + ':schemas>', Xmp);

    if q > 0 then begin
      tag := '<' + rdf + ':Bag>';
      k := Pos(tag, Copy(Xmp, q, MaxInt));
      q := q + k - 1;
      if (k > 0) and (q < p) then begin
        Insert(li, Xmp, q + Length(tag));
        p := p + Length(li);
        li := '';
      end else begin
        AddMsg(Msgs, abWarning, 'EMBED-XMP',
          'The existing PDF/A extension schema in the XMP has an unexpected form');
        exit;
      end;
    end;
  end;

  if li <> '' then desc := desc + ExtensionDescription(rdf);
  Insert(desc, Xmp, p);
  result := true;
end;

{ ===========================================================================
  Producer: a PDF written by abdecker says so, appended to the original
  producer ("Word; abdecker 0.1.0 (https://...)"). PDF/A wants the Info
  dictionary and the XMP (pdf:Producer) to agree, so both are set.
  =========================================================================== }

{ The producer with our part appended; an earlier part of ours is replaced }
function AbdeckerProducer(const Old: string): string;
var
  ours, s: string;
  start, stop: Integer;
begin
  ours := 'abdecker ' + AbdeckerVersion + ' (' + AbdeckerHome + ')';
  s := Trim(Old);
  if s = '' then exit(ours);

  if Copy(s, 1, 9) = 'abdecker ' then begin
    start := 1;
  end else begin
    start := Pos('; abdecker ', s);
    if start = 0 then exit(s + '; ' + ours);
    Inc(start, 2);
  end;
  // our part ends with the closing parenthesis of the link
  stop := Pos(')', Copy(s, start, MaxInt));

  if stop = 0 then begin
    stop := Length(s);
  end else begin
    stop := start + stop - 1;
  end;

  result := Copy(s, 1, start - 1) + ours + Copy(s, stop + 1, MaxInt);
end;

{ Sets pdf:Producer: replaces the existing value or adds a description }
function SetXmpProducer(var Xmp: string; const Producer: string): Boolean;
var
  pre, rdf, tag: string;
  p, q: Integer;
begin
  pre := PrefixOf(Xmp, NS_PDF);
  if (pre <> '') and ReplaceProp(Xmp, pre, 'Producer', Producer) then exit(true);
  result := false;
  rdf := PrefixOf(Xmp, NS_RDF);
  if rdf = '' then exit;
  p := 0;
  tag := '</' + rdf + ':RDF>';
  q := Pos(tag, Xmp);
  while q > 0 do begin
    p := p + q;
    q := Pos(tag, Copy(Xmp, p + 1, MaxInt));
  end;

  if p = 0 then exit;
  Insert('<' + rdf + ':Description ' + rdf + ':about="" xmlns:pdf="' + NS_PDF + '">'#10 +
    '<pdf:Producer>' + XmlEsc(Producer) + '</pdf:Producer>'#10 +
    '</' + rdf + ':Description>'#10, Xmp, p);
  result := true;
end;

{ ===========================================================================
  Name tree of the embedded files: flattened, merged, sorted
  =========================================================================== }

type
  TNameEntry = record
    Key: TBytes;
    Value: string;   // serialized value, usually 'n g R'
    Raw: Integer;    // pool index of the value (unresolved)
  end;
  TNameEntries = array of TNameEntry;

procedure CollectNames(var Pdf: TPdf; Node, Depth: Integer; var List: TNameEntries);
var
  a, i, k: Integer;
begin
  if (Node < 0) or (Depth > 32) or (Pdf.Vals[Node].Kind <> pkDict) then exit;
  a := Pdf.DGet(Node, 'Names');
  if (a >= 0) and (Pdf.Vals[a].Kind = pkArray) then begin
    i := 0;
    while i + 1 <= High(Pdf.Vals[a].Items) do begin
      k := Pdf.Resolve(Pdf.Vals[a].Items[i]);
      if (k >= 0) and (Pdf.Vals[k].Kind = pkString) then begin
        SetLength(List, Length(List) + 1);
        List[High(List)].Key := Pdf.Vals[k].Bytes;
        List[High(List)].Value := Pdf.ValueText(Pdf.Vals[a].Items[i + 1]);
        List[High(List)].Raw := Pdf.Vals[a].Items[i + 1];
      end;

      Inc(i, 2);
    end;
  end;

  a := Pdf.DGet(Node, 'Kids');
  if (a >= 0) and (Pdf.Vals[a].Kind = pkArray) then begin
    for i := 0 to High(Pdf.Vals[a].Items) do begin
      CollectNames(Pdf, Pdf.Resolve(Pdf.Vals[a].Items[i]), Depth + 1, List);
    end;
  end;
end;

function CompareKeys(const a, b: TBytes): Integer;
var
  i: Integer;
begin
  for i := 0 to IMin(Length(a), Length(b)) - 1 do begin
    if a[i] <> b[i] then exit(Integer(a[i]) - Integer(b[i]));
  end;

  result := Length(a) - Length(b);
end;

function HexString(const b: TBytes): string;
const
  Hex: array[0..15] of Char = '0123456789abcdef';
var
  i: Integer;
begin
  result := '<';

  for i := 0 to High(b) do begin
    result := result + Hex[b[i] shr 4] + Hex[b[i] and 15];
  end;

  result := result + '>';
end;

function NamesArrayText(var List: TNameEntries): string;
var
  i, j: Integer;
  t: TNameEntry;
begin
  for i := 1 to High(List) do begin
    t := List[i];
    j := i - 1;
    while (j >= 0) and (CompareKeys(List[j].Key, t.Key) > 0) do begin
      List[j + 1] := List[j];
      Dec(j);
    end;

    List[j + 1] := t;
  end;

  result := '[';

  for i := 0 to High(List) do begin
    if i > 0 then result := result + ' ';
    result := result + HexString(List[i].Key) + ' ' + List[i].Value;
  end;

  result := result + ']';
end;

{ ===========================================================================
  Removing the ZUGFeRD / Factur-X properties from the XMP
  =========================================================================== }

{ urn:factur-x:pdfa:CrossIndustryDocument:invoice:1p0#, its ZUGFeRD 2.0 and
  1.0 forms (urn:zugferd:..., urn:ferd:...). Not: other namespaces of the
  ZUGFeRD world, such as the additional data of the community. }
function IsFxNamespace(const NS: string): Boolean;
begin
  result := Pos('crossindustrydocument', LowerCase(NS)) > 0;
end;

{ Next declaration 'xmlns:pre="uri"' of a ZUGFeRD/Factur-X namespace at or
  after From. DeclPos: position of 'xmlns:'. }
function FindFxDecl(const Xmp: string; From: Integer; out DeclPos: Integer; out Pre: string): Boolean;
var
  p, q, e: Integer;
  quote: Char;
begin
  result := false;

  while true do begin
    p := Pos('xmlns:', Copy(Xmp, From, MaxInt));
    if p = 0 then exit;
    p := From + p - 1;
    From := p + 6;
    q := p + 6;
    while (q <= Length(Xmp)) and (Xmp[q] > ' ') and (Xmp[q] <> '=') do begin
      Inc(q);
    end;

    Pre := Copy(Xmp, p + 6, q - p - 6);

    while (q <= Length(Xmp)) and ((Xmp[q] <= ' ') or (Xmp[q] = '=')) do begin
      Inc(q);
    end;

    if (q > Length(Xmp)) or ((Xmp[q] <> '"') and (Xmp[q] <> '''')) then continue;
    quote := Xmp[q];
    e := q + 1;
    while (e <= Length(Xmp)) and (Xmp[e] <> quote) do begin
      Inc(e);
    end;

    if IsFxNamespace(Copy(Xmp, q + 1, e - q - 1)) then begin
      DeclPos := p;
      exit(true);
    end;
  end;
end;

{ Position of the '>' that ends the tag starting at From (quotes respected), 0 if none }
function TagEnd(const s: string; From: Integer): Integer;
var
  quote: Char;
begin
  result := From;
  quote := #0;

  while result <= Length(s) do begin
    if quote <> #0 then begin
      if s[result] = quote then quote := #0;
    end else if (s[result] = '"') or (s[result] = '''') then begin
      quote := s[result];
    end else if s[result] = '>' then exit;

    Inc(result);
  end;

  result := 0;
end;

{ True if Block (a complete rdf:Description element) holds nothing but
  properties with prefix Pre: element names, attribute names and nested
  elements are checked. }
function OnlyFxProperties(const Block, Rdf, Pre: string): Boolean;
var
  i, e: Integer;
  name: string;
  first, otherProp: Boolean;
  quote: Char;

  function ReadQName: string;
  var
    s: Integer;
  begin
    s := i;

    while (i <= Length(Block)) and (Block[i] > ' ') and (Block[i] <> '>') and (Block[i] <> '/') and
      (Block[i] <> '=') do
    begin
      Inc(i);
    end;

    result := Copy(Block, s, i - s);
  end;

  procedure SkipWS;
  begin
    while (i <= Length(Block)) and (Block[i] <= ' ') do begin
      Inc(i);
    end;
  end;

begin
  result := false;
  first := true;
  i := 1;
  while i <= Length(Block) do begin
    if Block[i] <> '<' then begin
      Inc(i);
      continue;
    end;

    if Copy(Block, i, 4) = '<!--' then begin
      e := Pos('-->', Copy(Block, i, MaxInt));
      if e = 0 then exit;
      i := i + e + 2;
      continue;
    end;

    if Copy(Block, i, 2) = '</' then begin
      e := TagEnd(Block, i);
      if e = 0 then exit;
      i := e + 1;
      continue;
    end;

    Inc(i);
    if (i > Length(Block)) or (Block[i] = '?') or (Block[i] = '!') then exit;
    name := ReadQName;

    if first then begin
      if name <> Rdf + ':Description' then exit;
      first := false;
    end else if Copy(name, 1, Length(Pre) + 1) <> Pre + ':' then exit;
    // attributes
    while true do begin
      SkipWS;
      if i > Length(Block) then exit;

      if Block[i] = '>' then begin
        Inc(i);
        break;
      end;

      if Copy(Block, i, 2) = '/>' then begin
        Inc(i, 2);
        break;
      end;

      name := ReadQName;
      if name = '' then exit;
      otherProp := (name <> Rdf + ':about') and (Copy(name, 1, 5) <> 'xmlns') and (Copy(name, 1, 4) <> 'xml:') and
        (Copy(name, 1, Length(Pre) + 1) <> Pre + ':');
      if otherProp then exit;
      SkipWS;
      if (i > Length(Block)) or (Block[i] <> '=') then exit;
      Inc(i);
      SkipWS;
      if (i > Length(Block)) or ((Block[i] <> '"') and (Block[i] <> '''')) then exit;
      quote := Block[i];
      Inc(i);

      while (i <= Length(Block)) and (Block[i] <> quote) do begin
        Inc(i);
      end;

      Inc(i);
    end;
  end;

  result := not first;
end;

{ For an rdf:Description that holds other properties as well: removes the
  declaration of Pre, the attributes Pre:* of the start tag and the child
  elements Pre:* (with the whitespace in front of them). False if anything
  with prefix Pre is left. }
function RemoveFxFromBlock(var Block: string; const Pre: string): Boolean;
var
  openEnd, i, wsStart, e, s, q: Integer;
  tag, name, close, local: string;
  quote: Char;
begin
  result := false;
  openEnd := TagEnd(Block, 1);
  if openEnd = 0 then exit;
  // start tag: keep everything but xmlns:Pre and Pre:* attributes
  i := 2;
  while (i <= openEnd) and (Block[i] > ' ') and (Block[i] <> '>') and (Block[i] <> '/') do begin
    Inc(i);
  end;

  tag := Copy(Block, 1, i - 1);

  while true do begin
    wsStart := i;

    while (i < openEnd) and (Block[i] <= ' ') do begin
      Inc(i);
    end;

    if (i >= openEnd) or (Block[i] = '/') then break;
    s := i;

    while (i < openEnd) and (Block[i] > ' ') and (Block[i] <> '=') do begin
      Inc(i);
    end;

    name := Copy(Block, s, i - s);

    while (i < openEnd) and (Block[i] <> '"') and (Block[i] <> '''') do begin
      Inc(i);
    end;

    if i >= openEnd then exit;
    quote := Block[i];
    Inc(i);

    while (i < openEnd) and (Block[i] <> quote) do begin
      Inc(i);
    end;

    Inc(i);

    if (name <> 'xmlns:' + Pre) and (Copy(name, 1, Length(Pre) + 1) <> Pre + ':') then begin
      tag := tag + Copy(Block, wsStart, i - wsStart);
    end;
  end;

  tag := tag + Copy(Block, wsStart, openEnd - wsStart + 1);
  Block := tag + Copy(Block, openEnd + 1, MaxInt);

  // child elements Pre:*
  while true do begin
    s := Pos('<' + Pre + ':', Block);
    if s = 0 then break;
    e := TagEnd(Block, s);
    if e = 0 then exit;

    if Block[e - 1] = '/' then begin
      e := e + 1;
    end else begin
      i := s + Length(Pre) + 2;
      while (i < e) and (Block[i] > ' ') and (Block[i] <> '>') do begin
        Inc(i);
      end;

      local := Copy(Block, s + Length(Pre) + 2, i - s - Length(Pre) - 2);
      close := '</' + Pre + ':' + local + '>';
      q := Pos(close, Copy(Block, e, MaxInt));
      if q = 0 then exit;
      e := e + q - 1 + Length(close);
    end;

    // the indentation and the line break in front go as well
    while (s > 1) and ((Block[s - 1] = ' ') or (Block[s - 1] = #9)) do begin
      Dec(s);
    end;

    if (s > 1) and (Block[s - 1] = #10) then Dec(s);
    if (s > 1) and (Block[s - 1] = #13) then Dec(s);
    Delete(Block, s, e - s);
  end;

  openEnd := TagEnd(Block, 1);
  if openEnd = 0 then exit;
  tag := Copy(Block, 1, openEnd);

  for i := 1 to Length(tag) do begin
    if tag[i] < ' ' then tag[i] := ' ';
  end;

  result := (Pos(' ' + Pre + ':', tag) = 0) and (Pos('xmlns:' + Pre + '=', tag) = 0);
end;

{ Removes the ZUGFeRD/Factur-X properties: an rdf:Description that holds
  nothing else goes as a whole. False if such properties remain (declared
  outside an rdf:Description, unexpected form); Changed tells whether
  anything was removed. }
function RemoveFxXmp(var Xmp: string; out Changed: Boolean): Boolean;
var
  noDescription: Boolean;
  rdf, pre, close, block: string;
  declPos, s, e, q, guard: Integer;
begin
  Changed := false;
  result := true;
  rdf := PrefixOf(Xmp, NS_RDF);
  guard := 0;

  while FindFxDecl(Xmp, 1, declPos, pre) do begin
    Inc(guard);
    if (rdf = '') or (guard > 16) then exit(false);
    // the declaration must sit on an rdf:Description start tag
    s := declPos;
    while (s > 1) and (Xmp[s] <> '<') do begin
      Dec(s);
    end;

    noDescription := (Copy(Xmp, s, Length(rdf) + 13) <> '<' + rdf + ':Description') or
      (s + Length(rdf) + 13 > Length(Xmp)) or (Xmp[s + Length(rdf) + 13] > ' ');
    if noDescription then exit(false);
    e := TagEnd(Xmp, s);
    if e = 0 then exit(false);

    if Xmp[e - 1] = '/' then begin
      e := e + 1;
    end else begin
      close := '</' + rdf + ':Description>';
      q := Pos(close, Copy(Xmp, e, MaxInt));
      if q = 0 then exit(false);
      e := e + q - 1 + Length(close);
    end;

    block := Copy(Xmp, s, e - s);
    if OnlyFxProperties(block, rdf, pre) then begin
      // the line break behind the element goes as well
      if (e <= Length(Xmp)) and (Xmp[e] = #13) then Inc(e);
      if (e <= Length(Xmp)) and (Xmp[e] = #10) then Inc(e);
      Delete(Xmp, s, e - s);
    end else begin
      if not RemoveFxFromBlock(block, pre) then exit(false);
      Xmp := Copy(Xmp, 1, s - 1) + block + Copy(Xmp, e, MaxInt);
    end;

    Changed := true;
  end;
end;

{ ===========================================================================
  Writing the incremental update
  =========================================================================== }

type
  TNewObj = record
    Num, Gen: Integer;
    Body: TBytes;    // everything between 'n g obj' and 'endobj'
  end;
  TNewObjs = array of TNewObj;

function PdfDate: string;
var
  y, mo, dd, h, mi, s, ms: Word;
begin
  DecodeDate(Now, y, mo, dd);
  DecodeTime(Now, h, mi, s, ms);
  result := Format('D:%.4d%.2d%.2d%.2d%.2d%.2d', [y, mo, dd, h, mi, s]);
end;

procedure PutBE(var Buf: TByteBuf; v: Int64; Width: Integer);
var
  i: Integer;
begin
  for i := Width - 1 downto 0 do begin
    Buf.Add(Byte((v shr (8 * i)) and $FF));
  end;
end;

function TextBytes(const s: string): TBytes;
var
  buf: TByteBuf;
begin
  buf.Clear;
  buf.AddText(s);
  result := buf.AsBytes;
end;

function StreamBody(const Dict: string; const Data: TBytes): TBytes;
var
  buf: TByteBuf;
begin
  buf.Clear;
  buf.AddText(Dict + #10'stream'#10);
  buf.AddBytes(Data);
  buf.AddText(#10'endstream');
  result := buf.AsBytes;
end;

procedure AddObj(var Objs: TNewObjs; Num, Gen: Integer; const Body: TBytes);
begin
  SetLength(Objs, Length(Objs) + 1);
  Objs[High(Objs)].Num := Num;
  Objs[High(Objs)].Gen := Gen;
  Objs[High(Objs)].Body := Body;
end;

{ Opens a PDF for an incremental update: refuses broken (reconstructed) and
  encrypted files. FirstFree: first unused object number. }
function OpenForUpdate(const PdfData: TBytes; var Pdf: TPdf; out Cat, CatNum, CatGen,
  FirstFree: Integer; const Prefix: string; var Msgs: TAbMessages): TAbResult;
var
  m: TAbMessages;
  rootRaw: Integer;
begin
  Cat := -1;
  CatNum := 0;
  CatGen := 0;
  FirstFree := 0;
  m := nil;
  if not Pdf.Open(PdfData, m) or Pdf.Rebuilt or (Pdf.StartXRef < 0) then begin
    AddMsg(Msgs, abError, Prefix + '-BROKEN',
      'The PDF structure is broken, an update cannot be appended safely');
    exit(abBrokenPDF);
  end;

  if Pdf.Encrypted then begin
    AddMsg(Msgs, abError, 'PDF-ENCRYPTED', 'The PDF is encrypted. Encrypted PDFs are not supported.');
    exit(abEncrypted);
  end;

  Cat := Pdf.Catalog;
  rootRaw := Pdf.DRaw(Pdf.Trailer, 'Root');
  if (Cat < 0) or (rootRaw < 0) or (Pdf.Vals[rootRaw].Kind <> pkRef) then begin
    AddMsg(Msgs, abError, Prefix + '-BROKEN', 'The PDF catalog cannot be found');
    exit(abBrokenPDF);
  end;

  CatNum := Integer(Pdf.Vals[rootRaw].Int);
  CatGen := Pdf.Vals[rootRaw].Gen;
  FirstFree := Integer(Pdf.DInt(Pdf.Trailer, 'Size', 0));
  if FirstFree < Length(Pdf.Entries) then FirstFree := Length(Pdf.Entries);
  if FirstFree <= CatNum then FirstFree := CatNum + 1;
  result := abOK;
end;

{ Producer from the Info dictionary of the original ('' if none) }
function InfoProducer(var Pdf: TPdf): string;
begin
  result := Pdf.DText(Pdf.DGet(Pdf.Trailer, 'Info'), 'Producer');
end;

{ New version of the Info dictionary with the producer, all other entries
  unchanged; a new object if the original has none (or a direct one).
  Returns the reference for the trailer. }
function InfoObject(var Pdf: TPdf; const Producer: string; var Objs: TNewObjs; NewNum: Integer): string;
var
  raw, info, num, gen, i: Integer;
  s: string;
begin
  raw := Pdf.DRaw(Pdf.Trailer, 'Info');
  info := Pdf.DGet(Pdf.Trailer, 'Info');

  if (raw >= 0) and (Pdf.Vals[raw].Kind = pkRef) then begin
    num := Integer(Pdf.Vals[raw].Int);
    gen := Pdf.Vals[raw].Gen;
  end else begin
    num := NewNum;
    gen := 0;
  end;

  s := '<<';

  if (info >= 0) and (Pdf.Vals[info].Kind = pkDict) then begin
    for i := 0 to High(Pdf.Vals[info].Keys) do begin
      if Pdf.Vals[info].Keys[i] = 'Producer' then continue;
      s := s + ' ' + PdfNameText(Pdf.Vals[info].Keys[i]) + ' ' + Pdf.ValueText(Pdf.Vals[info].Items[i]);
    end;
  end;

  s := s + ' /Producer ' + PdfTextString(Producer) + ' >>';
  AddObj(Objs, num, gen, TextBytes(s));
  result := IntToStr(num) + ' ' + IntToStr(gen) + ' R';
end;

{ Self-check: Info and XMP of the result carry the producer }
function ProducerOK(const OutPdf: TBytes; const Producer: string): Boolean;
var
  pdf: TPdf;
  m: TAbMessages;
  meta: TBytes;
begin
  m := nil;
  result := pdf.Open(OutPdf, m) and (InfoProducer(pdf) = Producer);
  if result and pdf.MetadataXML(meta) and (Length(meta) > 0) then begin
    result := Pos(XmlEsc(Producer), Utf8Str(meta, 0, Length(meta))) > 0;
  end;
end;

{ Appends the objects and a cross-reference section in the form of the
  original (table or stream) to the unchanged original bytes. InfoRef: new
  /Info for the trailer ('' = keep the original one). }
function AppendUpdate(var Pdf: TPdf; const PdfData: TBytes; Objs: TNewObjs;
  CatNum, CatGen, FirstFree: Integer; const InfoRef: string): TBytes;
var
  buf, xBuf: TByteBuf;
  ofs: array of Integer;
  i, j, k, size, xRefNum, xRefPos: Integer;
  t: TNewObj;
  index: string;

  procedure TrailerEntries;
  var
    v: Integer;
  begin
    buf.AddText(' /Root ' + IntToStr(CatNum) + ' ' + IntToStr(CatGen) + ' R');
    v := Pdf.DRaw(Pdf.Trailer, 'Info');
    if InfoRef <> '' then begin
      buf.AddText(' /Info ' + InfoRef);
    end else if v >= 0 then begin
      buf.AddText(' /Info ' + Pdf.ValueText(v));
    end;

    v := Pdf.DRaw(Pdf.Trailer, 'ID');
    if v >= 0 then begin
      buf.AddText(' /ID ' + Pdf.ValueText(v));
    end;

    buf.AddText(' /Prev ' + IntToStr(Pdf.StartXRef));
  end;

  { last index of the run of consecutive object numbers starting at I }
  function RunEnd(i: Integer): Integer;
  begin
    result := i;
    while (result < High(Objs)) and (Objs[result + 1].Num = Objs[result].Num + 1) do begin
      Inc(result);
    end;
  end;

begin
  for i := 1 to High(Objs) do begin
    t := Objs[i];
    j := i - 1;
    while (j >= 0) and (Objs[j].Num > t.Num) do begin
      Objs[j + 1] := Objs[j];
      Dec(j);
    end;

    Objs[j + 1] := t;
  end;

  size := FirstFree;

  for i := 0 to High(Objs) do begin
    if Objs[i].Num >= size then size := Objs[i].Num + 1;
  end;

  buf.Clear;

  // start the update on a fresh line
  if (Length(PdfData) > 0) and (PdfData[High(PdfData)] <> 10) and (PdfData[High(PdfData)] <> 13) then begin
    buf.AddText(#10);
  end;

  SetLength(ofs, Length(Objs));

  for i := 0 to High(Objs) do begin
    ofs[i] := Length(PdfData) + buf.Len;
    buf.AddText(IntToStr(Objs[i].Num) + ' ' + IntToStr(Objs[i].Gen) + ' obj'#10);
    buf.AddBytes(Objs[i].Body);
    buf.AddText(#10'endobj'#10);
  end;

  xRefPos := Length(PdfData) + buf.Len;

  if Pdf.XRefIsStream then begin
    // the stream lists itself as well, with the highest number
    xRefNum := size;
    Inc(size);
    AddObj(Objs, xRefNum, 0, nil);
    SetLength(ofs, Length(Objs));
    ofs[High(ofs)] := xRefPos;
    xBuf.Clear;
    index := '';
    i := 0;
    while i <= High(Objs) do begin
      j := RunEnd(i);
      index := index + ' ' + IntToStr(Objs[i].Num) + ' ' + IntToStr(j - i + 1);

      for k := i to j do begin
        xBuf.Add(1);
        PutBE(xBuf, ofs[k], 4);
        PutBE(xBuf, Objs[k].Gen, 2);
      end;

      i := j + 1;
    end;

    buf.AddText(IntToStr(xRefNum) + ' 0 obj'#10'<< /Type /XRef /Size ' + IntToStr(size) +
      ' /W [1 4 2] /Index [' + Trim(index) + ']');
    TrailerEntries;
    buf.AddText(' /Length ' + IntToStr(xBuf.Len) + ' >>'#10'stream'#10);
    buf.AddBytes(xBuf.AsBytes);
    buf.AddText(#10'endstream'#10'endobj'#10);
  end else begin
    buf.AddText('xref'#10);
    i := 0;
    while i <= High(Objs) do begin
      j := RunEnd(i);
      buf.AddText(IntToStr(Objs[i].Num) + ' ' + IntToStr(j - i + 1) + #10);

      for k := i to j do begin
        buf.AddText(Format('%.10d %.5d n'#13#10, [ofs[k], Objs[k].Gen]));
      end;

      i := j + 1;
    end;

    buf.AddText('trailer'#10'<< /Size ' + IntToStr(size));
    TrailerEntries;
    buf.AddText(' >>'#10);
  end;

  buf.AddText('startxref'#10 + IntToStr(xRefPos) + #10'%%EOF'#10);

  SetLength(result, Length(PdfData) + buf.Len);

  if Length(PdfData) > 0 then begin
    Move(PdfData[0], result[0], Length(PdfData));
  end;

  if buf.Len > 0 then begin
    Move(buf.Data[0], result[Length(PdfData)], buf.Len);
  end;
end;

{ ===========================================================================
  Embed
  =========================================================================== }

function EmbedInvoice(const PdfData, Xml: TBytes; const XmlName, Level, Relationship,
  PdfAPart: string; out OutPdf: TBytes; var Msgs: TAbMessages): TAbResult;
var
  utf16: Boolean;
  pdf: TPdf;
  cat, catNum, catGen, base, numEF, numFS, numMeta, i, d, n: Integer;
  zipped, meta, oldMeta, nameKey: TBytes;
  s, key, xmpText, oldXmp, ver, producer, infoRef: string;
  names: TNameEntries;
  hasOld: Boolean;
  objs: TNewObjs;
begin
  OutPdf := nil;
  result := OpenForUpdate(PdfData, pdf, cat, catNum, catGen, base, 'EMBED', Msgs);
  if result <> abOK then exit;
  producer := AbdeckerProducer(InfoProducer(pdf));
  numEF := base;
  numFS := base + 1;
  numMeta := base + 2;

  // XMP: extend the existing packet, or start a new one
  oldXmp := '';
  hasOld := pdf.MetadataXML(oldMeta) and (Length(oldMeta) > 0);
  if hasOld then begin
    utf16 := (Length(oldMeta) >= 2) and (((oldMeta[0] = $FE) and (oldMeta[1] = $FF)) or
      ((oldMeta[0] = $FF) and (oldMeta[1] = $FE)));

    if utf16 then begin
      AddMsg(Msgs, abError, 'EMBED-XMP', 'XMP metadata in UTF-16 is not supported');
      exit(abUnsupported);
    end;

    oldXmp := Utf8Str(oldMeta, 0, Length(oldMeta));
    if (oldXmp <> '') and (oldXmp[1] = #$FEFF) then begin
      Delete(oldXmp, 1, 1);
    end;
  end;

  if (PdfAPart = '1') or (PdfAPart = '2') then begin
    if not SetPdfAPart3(oldXmp) then begin
      AddMsg(Msgs, abWarning, 'EMBED-PDFA', 'The PDF/A identification in the XMP could not be set to PDF/A-3');
    end;

    if PdfAPart = '1' then begin
      AddMsg(Msgs, abWarning, 'EMBED-PDFA1',
        'The PDF was PDF/A-1 and is now marked as PDF/A-3. Whether it conforms to PDF/A-3 ' +
        'has not been checked (use e.g. veraPDF).');
    end;
  end;

  if not hasOld or not MergeXmp(oldXmp, XmlName, Level, Msgs, xmpText) then begin
    if hasOld then begin
      AddMsg(Msgs, abWarning, 'EMBED-XMP', 'The existing XMP metadata could not be extended and was replaced');
    end;

    xmpText := NewXmp(XmlName, Level);
  end;
  // Info and XMP carry the producer together, or neither does
  if not SetXmpProducer(xmpText, producer) then producer := '';
  meta := Utf8Bytes(xmpText);

  try
    objs := nil;
    // embedded file
    zipped := DeflateBytes(Xml);
    AddObj(objs, numEF, 0, StreamBody('<< /Type /EmbeddedFile /Subtype /text#2Fxml /Params << /Size ' +
      IntToStr(Length(Xml)) + ' /ModDate (' + PdfDate + ') >> /Filter /FlateDecode /Length ' +
      IntToStr(Length(zipped)) + ' >>', zipped));

    // file specification
    AddObj(objs, numFS, 0, TextBytes('<< /Type /Filespec /F (' + XmlName + ') /UF (' + XmlName +
      ') /Desc (Invoice) /AFRelationship /' + Relationship + ' /EF << /F ' + IntToStr(numEF) +
      ' 0 R /UF ' + IntToStr(numEF) + ' 0 R >> >>'));

    // metadata (PDF/A: not filtered)
    AddObj(objs, numMeta, 0, StreamBody('<< /Type /Metadata /Subtype /XML /Length ' +
      IntToStr(Length(meta)) + ' >>', meta));

    // new version of the catalog; associated files need PDF 1.7
    ver := pdf.DName(cat, 'Version');
    if CompareStr(pdf.Version, ver) > 0 then ver := pdf.Version;
    s := '<<';

    for i := 0 to High(pdf.Vals[cat].Keys) do begin
      key := pdf.Vals[cat].Keys[i];
      if (key = 'Names') or (key = 'AF') or (key = 'Metadata') then continue;
      if (key = 'Version') and (CompareStr(ver, '1.7') < 0) then continue;
      s := s + ' ' + PdfNameText(key) + ' ' + pdf.ValueText(pdf.Vals[cat].Items[i]);
    end;

    if CompareStr(ver, '1.7') < 0 then s := s + ' /Version /1.7';
    // names: keep everything, merge the embedded files
    s := s + ' /Names <<';
    d := pdf.DGet(cat, 'Names');
    names := nil;

    if (d >= 0) and (pdf.Vals[d].Kind = pkDict) then begin
      for i := 0 to High(pdf.Vals[d].Keys) do begin
        if pdf.Vals[d].Keys[i] <> 'EmbeddedFiles' then begin
          s := s + ' ' + PdfNameText(pdf.Vals[d].Keys[i]) + ' ' + pdf.ValueText(pdf.Vals[d].Items[i]);
        end;
      end;

      CollectNames(pdf, pdf.DGet(d, 'EmbeddedFiles'), 0, names);
    end;
    // an attachment of the same name is replaced
    nameKey := TEncoding.ASCII.GetBytes(XmlName);
    n := 0;

    for i := 0 to High(names) do begin
      if CompareKeys(names[i].Key, nameKey) <> 0 then begin
        names[n] := names[i];
        Inc(n);
      end;
    end;

    SetLength(names, n + 1);
    names[n].Key := nameKey;
    names[n].Value := IntToStr(numFS) + ' 0 R';
    s := s + ' /EmbeddedFiles << /Names ' + NamesArrayText(names) + ' >> >>';
    // associated files
    s := s + ' /AF [';
    d := pdf.DGet(cat, 'AF');
    if (d >= 0) and (pdf.Vals[d].Kind = pkArray) then begin
      for i := 0 to High(pdf.Vals[d].Items) do begin
        s := s + pdf.ValueText(pdf.Vals[d].Items[i]) + ' ';
      end;
    end;

    s := s + IntToStr(numFS) + ' 0 R]';
    s := s + ' /Metadata ' + IntToStr(numMeta) + ' 0 R >>';
    AddObj(objs, catNum, catGen, TextBytes(s));
    infoRef := '';
    if producer <> '' then infoRef := InfoObject(pdf, producer, objs, base + 3);

    OutPdf := AppendUpdate(pdf, PdfData, objs, catNum, catGen, base, infoRef);
  except
    on e: EAbParse do begin
      OutPdf := nil;
      AddMsg(Msgs, abError, 'EMBED-BROKEN', 'The PDF cannot be updated: ' + e.Message);
      exit(abBrokenPDF);
    end;
  end;

  if (producer <> '') and not ProducerOK(OutPdf, producer) then begin
    OutPdf := nil;
    AddMsg(Msgs, abError, 'EMBED-VERIFY', 'Self-check: the producer is not set (please report)');
    exit(abInternalError);
  end;

  result := abOK;
end;

{ ===========================================================================
  Strip
  =========================================================================== }

{ zlib data of exactly N bytes that inflates to zeros (stored blocks), so
  that a stream keeps its length and stays valid; nil if N is too small }
function ZeroZlib(n: Integer): TBytes;
var
  blocks, payload, p, i, k, len: Integer;
  adler: Cardinal;
begin
  result := nil;
  blocks := 1;
  while n - 6 - 5 * blocks > 65535 * blocks do begin
    Inc(blocks);
  end;

  payload := n - 6 - 5 * blocks;
  if payload < 0 then exit;
  SetLength(result, n);
  FillChar(result[0], n, 0);
  result[0] := $78;  // deflate, 32K window; header check: $7801 mod 31 = 0
  result[1] := $01;
  p := 2;
  k := payload;

  for i := 1 to blocks do begin
    if i = blocks then begin
      len := k;
      result[p] := 1;  // BFINAL, BTYPE 00 (stored)
    end else begin
      len := IMin(k, 65535);
    end;

    result[p + 1] := Byte(len);
    result[p + 2] := Byte(len shr 8);
    result[p + 3] := Byte(not len);
    result[p + 4] := Byte((not len) shr 8);
    Inc(p, 5 + len);
    Dec(k, len);
  end;
  // Adler-32 of zeros: A = 1, B = count
  adler := (Cardinal(payload mod 65521) shl 16) or 1;
  result[p] := Byte(adler shr 24);
  result[p + 1] := Byte(adler shr 16);
  result[p + 2] := Byte(adler shr 8);
  result[p + 3] := Byte(adler);
end;

{ True if one of the objects can be reached from the trailer of the newest
  revision (catalog, pages, annotations, structure tree, info ...) }
function Reachable(var Pdf: TPdf; const Nums: array of Int64): Boolean;
var
  seen: array of Boolean;
  stack: array of Integer;
  sp, v, i: Integer;
  n: Int64;

  procedure Push(x: Integer);
  begin
    if x < 0 then exit;

    if sp >= Length(stack) then begin
      SetLength(stack, sp * 2 + 64);
    end;

    stack[sp] := x;
    Inc(sp);
  end;

begin
  result := false;
  SetLength(seen, Length(Pdf.Entries));
  sp := 0;
  Push(Pdf.Trailer);

  while sp > 0 do begin
    Dec(sp);
    v := stack[sp];

    case Pdf.Vals[v].Kind of
      pkRef:
        begin
          n := Pdf.Vals[v].Int;

          for i := 0 to High(Nums) do begin
            if Nums[i] = n then exit(true);
          end;

          if (n >= 0) and (n < Length(seen)) and not seen[n] then begin
            seen[n] := true;
            Push(Pdf.GetObject(n));
          end;
        end;
      pkArray, pkDict, pkStream:
        for i := 0 to High(Pdf.Vals[v].Items) do begin
          Push(Pdf.Vals[v].Items[i]);
        end;
    end;
  end;
end;

{ A signature covers the original bytes: they must not change }
function IsSigned(var Pdf: TPdf; const PdfData: TBytes): Boolean;
begin
  result := (FindAt(PdfData, Length(PdfData), 0, '/ByteRange') >= 0) or
    ((Pdf.DInt(Pdf.DGet(Pdf.Catalog, 'AcroForm'), 'SigFlags', 0) and 1) <> 0);
end;

{ Overwrites the data of the embedded file streams in OutPdf (same offsets as
  in the original) and reads them back. Flate streams get valid zlib data
  that inflates to zeros, others zeros. }
function WipeStreams(var Pdf: TPdf; const Nums: array of Int64; var OutPdf: TBytes): Boolean;
var
  i, j, s, p, len: Integer;
  z, data: TBytes;
  flate: array of Boolean;
  check: TPdf;
  m: TAbMessages;
  err: string;
begin
  result := false;
  SetLength(flate, Length(Nums));

  for i := 0 to High(Nums) do begin
    s := Pdf.GetObject(Nums[i]);
    if (s < 0) or (Pdf.Vals[s].Kind <> pkStream) then exit;
    p := Pdf.Vals[s].StmPos;
    len := Pdf.Vals[s].StmLen;
    if (p <= 0) or (len < 0) or (p + len > Length(Pdf.b)) then exit;
    z := nil;

    if (Pdf.DName(s, 'Filter') = 'FlateDecode') and not Pdf.DHas(s, 'DecodeParms') then begin
      z := ZeroZlib(len);
    end;

    flate[i] := z <> nil;

    if flate[i] then begin
      Move(z[0], OutPdf[p], len);
    end else if len > 0 then begin
      FillChar(OutPdf[p], len, 0);
    end;
  end;
  // read back: the streams are still readable (in the earlier revision) and empty
  m := nil;
  if not check.Open(OutPdf, m) or check.Rebuilt then exit;

  for i := 0 to High(Nums) do begin
    s := check.GetObject(Nums[i]);
    if (s < 0) or (check.Vals[s].Kind <> pkStream) then exit;
    if not flate[i] and check.DHas(s, 'Filter') then continue;
    if not check.StreamData(s, data, err) then exit;

    for j := 0 to High(data) do begin
      if data[j] <> 0 then exit;
    end;
  end;

  result := true;
end;

function StripInvoice(const PdfData: TBytes; const XmlName: string; out OutPdf: TBytes;
  var Msgs: TAbMessages): TAbResult;
var
  pdf: TPdf;
  cat, catNum, catGen, base, i, d, n, idx, fs, ef, v: Integer;
  spec: Int64;
  streamNums, targets: array of Int64;
  after: TPdf;
  m: TAbMessages;
  files: TPdfFiles;
  names: TNameEntries;
  s, inner, af, keyName, xmpText, producer, infoRef: string;
  oldMeta, meta: TBytes;
  objs: TNewObjs;
  newMeta, changed, utf16: Boolean;

  { the value (unresolved) is the file specification of the invoice }
  function IsSpec(Raw: Integer): Boolean;
  begin
    if Raw < 0 then begin
      result := false;
    end else if spec >= 0 then begin
      result := (pdf.Vals[Raw].Kind = pkRef) and (pdf.Vals[Raw].Int = spec);
    end else begin
      result := Raw = -1 - spec;
    end;
  end;

begin
  OutPdf := nil;
  result := OpenForUpdate(PdfData, pdf, cat, catNum, catGen, base, 'STRIP', Msgs);
  if result <> abOK then exit;
  files := pdf.EmbeddedFiles;
  idx := -1;

  for i := 0 to High(files) do begin
    if (files[i].Name = XmlName) and (files[i].Stream >= 0) then begin
      idx := i;
      break;
    end;
  end;

  if idx < 0 then begin
    AddMsg(Msgs, abError, 'STRIP-NOT-FOUND',
      Format('The invoice file "%s" is not listed in the PDF catalog', [XmlName]));
    exit(abNoInvoice);
  end;

  spec := files[idx].Key;

  // XMP: the ZUGFeRD/Factur-X properties go, everything else stays; Info
  // and XMP get the producer together, or neither does
  newMeta := false;
  xmpText := '';
  producer := AbdeckerProducer(InfoProducer(pdf));

  if pdf.MetadataXML(oldMeta) and (Length(oldMeta) > 0) then begin
    utf16 := (Length(oldMeta) >= 2) and (((oldMeta[0] = $FE) and (oldMeta[1] = $FF)) or
      ((oldMeta[0] = $FF) and (oldMeta[1] = $FE)));

    if utf16 then begin
      AddMsg(Msgs, abWarning, 'STRIP-XMP',
        'XMP metadata in UTF-16 is not supported, its ZUGFeRD/Factur-X data was left in place');
      producer := '';
    end else begin
      xmpText := Utf8Str(oldMeta, 0, Length(oldMeta));
      if (xmpText <> '') and (xmpText[1] = #$FEFF) then begin
        Delete(xmpText, 1, 1);
      end;

      if not RemoveFxXmp(xmpText, changed) then begin
        AddMsg(Msgs, abWarning, 'STRIP-XMP',
          'The ZUGFeRD/Factur-X data in the XMP metadata could not be removed completely');
      end;

      newMeta := changed;

      if SetXmpProducer(xmpText, producer) then begin
        newMeta := true;
      end else begin
        producer := '';
      end;
    end;
  end;

  try
    objs := nil;
    s := '<<';

    for i := 0 to High(pdf.Vals[cat].Keys) do begin
      keyName := pdf.Vals[cat].Keys[i];
      if (keyName = 'Names') or (keyName = 'AF') or (newMeta and (keyName = 'Metadata')) then begin
        continue;
      end;

      s := s + ' ' + PdfNameText(keyName) + ' ' + pdf.ValueText(pdf.Vals[cat].Items[i]);
    end;
    // names: everything else stays, the invoice leaves the embedded files
    d := pdf.DGet(cat, 'Names');
    if (d >= 0) and (pdf.Vals[d].Kind = pkDict) then begin
      inner := '';

      for i := 0 to High(pdf.Vals[d].Keys) do begin
        if pdf.Vals[d].Keys[i] <> 'EmbeddedFiles' then begin
          inner := inner + ' ' + PdfNameText(pdf.Vals[d].Keys[i]) + ' ' + pdf.ValueText(pdf.Vals[d].Items[i]);
        end;
      end;

      names := nil;
      CollectNames(pdf, pdf.DGet(d, 'EmbeddedFiles'), 0, names);
      n := 0;

      for i := 0 to High(names) do begin
        if not IsSpec(names[i].Raw) then begin
          names[n] := names[i];
          Inc(n);
        end;
      end;

      SetLength(names, n);
      if n > 0 then inner := inner + ' /EmbeddedFiles << /Names ' + NamesArrayText(names) + ' >>';
      if inner <> '' then s := s + ' /Names <<' + inner + ' >>';
    end;
    // associated files
    d := pdf.DGet(cat, 'AF');
    if (d >= 0) and (pdf.Vals[d].Kind = pkArray) then begin
      af := '';

      for i := 0 to High(pdf.Vals[d].Items) do begin
        if not IsSpec(pdf.Vals[d].Items[i]) then begin
          af := af + ' ' + pdf.ValueText(pdf.Vals[d].Items[i]);
        end;
      end;

      if af <> '' then s := s + ' /AF [' + Trim(af) + ']';
    end;

    if newMeta then begin
      meta := Utf8Bytes(xmpText);
      AddObj(objs, base, 0, StreamBody('<< /Type /Metadata /Subtype /XML /Length ' +
        IntToStr(Length(meta)) + ' >>', meta));
      s := s + ' /Metadata ' + IntToStr(base) + ' 0 R';
    end;

    AddObj(objs, catNum, catGen, TextBytes(s + ' >>'));
    infoRef := '';
    if producer <> '' then infoRef := InfoObject(pdf, producer, objs, base + 1);

    OutPdf := AppendUpdate(pdf, PdfData, objs, catNum, catGen, base, infoRef);

    // the XML itself: no longer referenced, so its data can be overwritten in
    // place (same length, offsets stay valid) - unless a signature covers it
    // or other parts of the document still refer to it
    streamNums := nil;

    if spec >= 0 then begin
      fs := pdf.GetObject(spec);
    end else begin
      fs := pdf.Resolve(Integer(-1 - spec));
    end;

    ef := pdf.DGet(fs, 'EF');
    if (ef >= 0) and (pdf.Vals[ef].Kind = pkDict) then begin
      for i := 0 to High(pdf.Vals[ef].Items) do begin
        v := pdf.Vals[ef].Items[i];
        if pdf.Vals[v].Kind <> pkRef then continue;
        n := 0;
        while (n < Length(streamNums)) and (streamNums[n] <> pdf.Vals[v].Int) do begin
          Inc(n);
        end;

        if n = Length(streamNums) then begin
          SetLength(streamNums, n + 1);
          streamNums[n] := pdf.Vals[v].Int;
        end;
      end;
    end;

    targets := Copy(streamNums, 0, Length(streamNums));

    if spec >= 0 then begin
      SetLength(targets, Length(targets) + 1);
      targets[High(targets)] := spec;
    end;

    m := nil;

    if IsSigned(pdf, PdfData) then begin
      AddMsg(Msgs, abInfo, 'STRIP-SIGNED', 'The PDF is signed: the XML data stays in the earlier ' +
        'revision of the file, so that the signature remains valid');
    end else if not after.Open(OutPdf, m) or (Length(streamNums) = 0) then begin
      OutPdf := nil;
      AddMsg(Msgs, abError, 'STRIP-VERIFY', 'The generated PDF fails the self-check (please report)');
      exit(abInternalError);
    end else if Reachable(after, targets) then begin
      AddMsg(Msgs, abInfo, 'STRIP-REFERENCED', 'The XML data stays in the file because other parts ' +
        'of the PDF still refer to it');
    end else if not WipeStreams(pdf, streamNums, OutPdf) then begin
      OutPdf := nil;
      AddMsg(Msgs, abError, 'STRIP-WIPE', 'The XML data could not be overwritten (please report)');
      exit(abInternalError);
    end;
  except
    on e: EAbParse do begin
      OutPdf := nil;
      AddMsg(Msgs, abError, 'STRIP-BROKEN', 'The PDF cannot be updated: ' + e.Message);
      exit(abBrokenPDF);
    end;
  end;

  if (producer <> '') and not ProducerOK(OutPdf, producer) then begin
    OutPdf := nil;
    AddMsg(Msgs, abError, 'STRIP-VERIFY', 'Self-check: the producer is not set (please report)');
    exit(abInternalError);
  end;

  result := abOK;
end;

end.
