{ SPDX-License-Identifier: MIT
  Copyright (c) 2026 Ingo Jache }

unit abdecker.json;

{ abdecker - JSON (internal): results as JSON and a small JSON reader. Not
  part of the public API: use the unit abdecker (TAbdecker.InfoToJson,
  CheckToJson, MessagesToJson and the code words ResultCode, ProfileCode ...).

  The results are the common output format of the command line (--json) and
  of the server (serve), so they are part of the interface: fields are only
  ever added, never renamed or removed. Line breaks are #10 on every platform.

  The reader (JsonParse) is strict RFC 8259, without floating point: numbers
  stay text, exactly as written. }

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
  TJKind = (jkNull, jkFalse, jkTrue, jkNumber, jkString, jkArray, jkObject);

  { A value of the JSON document. The nodes are a flat array (no objects, no
    pointers), parent/child/sibling links are indices, -1 = none. }
  TJNode = record
    Kind: TJKind;
    Name: string;     // member name if the parent is an object, else ''
    Value: string;    // string: the decoded text; number: as written; else ''
    Parent, FirstChild, LastChild, Next: Integer;
    Line, Col: Integer;  // where the value starts, 1-based; column in characters
    NameLine, NameCol: Integer;  // where the member name starts (0 if none)
  end;

  TJDoc = record
    Nodes: array of TJNode;  // Nodes[0] is the top-level value
    Count: Integer;
    Error: string;           // why parsing failed, with line and column
    ErrorLine, ErrorCol: Integer;
    { first member of object N with this name, -1 if none (or N is no object) }
    function Member(n: Integer; const Name: string): Integer;
    { members separated by '/', relative to N, e.g. 'seller/contact/name' }
    function Path(n: Integer; const APath: string): Integer;
  end;

{ Parses UTF-8 JSON (a leading BOM is skipped). Strict: no comments, no
  trailing commas, valid UTF-8, no lone surrogates; nesting depth at most 512. }
function JsonParse(const Data: TBytes; out Doc: TJDoc): Boolean;

function JsonStr(const s: string): string;
{ "  "messages": [ ... ]" with one message per line (member of a result) }
function MessageList(const Msgs: TAbMessages): string;
function InfoJson(const FileName: string; r: TAbResult; const Info: TEInvoiceInfo;
  const Msgs: TAbMessages): string;
function CheckJson(const FileName: string; r: TAbResult; const Inv: TEInvoice;
  const Report: TAbCheckReport; WithRules: Boolean): string;
function MessagesJson(const AResult: string; const Msgs: TAbMessages): string;
function AttachmentsJson(const FileName: string; r: TAbResult; const Files: TEInvoiceFiles;
  const Msgs: TAbMessages; WithContent: Boolean): string;

const
  ResultCodes: array[TAbResult] of string = ('ok', 'no-invoice', 'unknown-format',
    'file-error', 'broken-pdf', 'broken-xml', 'encrypted', 'unsupported', 'invalid-data', 'internal-error');
  SyntaxCodes: array[TEInvoiceSyntax] of string = ('', 'cii', 'ubl-invoice', 'ubl-creditnote', 'zugferd1');
  ProfileCodes: array[TEInvoiceProfile] of string = ('', 'minimum', 'basicwl', 'basic', 'comfort',
    'en16931', 'extended', 'xrechnung', 'peppol');
  ContainerCodes: array[TEInvoiceContainer] of string = ('', 'xml', 'pdf');
  SeverityCodes: array[TAbSeverity] of string = ('info', 'warning', 'error');
  OriginCodes: array[TAbOrigin] of string = ('file', 'official', 'extra');
  RuleStatusCodes: array[TAbRuleStatus] of string = ('not-applied', 'passed', 'failed');
  FileSourceCodes: array[TEInvoiceFileSource] of string = ('pdf', 'invoice');

implementation

uses
  abdecker.util;

const
  LF = #10;

function JsonStr(const s: string): string;
var
  i: Integer;
  c: Char;
begin
  result := '"';

  for i := 1 to Length(s) do begin
    c := s[i];

    case c of
      '"': result := result + '\"';
      '\': result := result + '\\';
      #8: result := result + '\b';
      #9: result := result + '\t';
      #10: result := result + '\n';
      #12: result := result + '\f';
      #13: result := result + '\r';
    else
      if c < #32 then begin
        result := result + '\u' + IntToHex(Ord(c), 4);
      end else begin
        result := result + c;
      end;
    end;
  end;

  result := result + '"';
end;

function BoolJson(b: Boolean): string;
begin
  if b then begin
    result := 'true';
  end else begin
    result := 'false';
  end;
end;

function MessageJson(const m: TAbMessage): string;
begin
  result := '{"severity": ' + JsonStr(SeverityCodes[m.Severity]) + ', "code": ' + JsonStr(m.Code) +
    ', "origin": ' + JsonStr(OriginCodes[m.Origin]) + ', "text": ' + JsonStr(m.Text) + '}';
end;

function MessageList(const Msgs: TAbMessages): string;
var
  i: Integer;
begin
  result := '  "messages": [';

  for i := 0 to High(Msgs) do begin
    if i > 0 then result := result + ',';
    result := result + LF + '    ' + MessageJson(Msgs[i]);
  end;

  if Length(Msgs) > 0 then result := result + LF + '  ';
  result := result + ']';
end;

function StrList(const l: TAbStrings): string;
var
  i: Integer;
begin
  result := '[';

  for i := 0 to High(l) do begin
    if i > 0 then result := result + ', ';
    result := result + JsonStr(l[i]);
  end;

  result := result + ']';
end;

{ top-level member: "  "key": value," }
function Member(const Key, Value: string; Comma: Boolean = true): string;
begin
  result := '  ' + JsonStr(Key) + ': ' + Value;
  if Comma then result := result + ',';
  result := result + LF;
end;

{ member of a nested object: "    "key": "value"," }
function Field(const Key, Value: string; Comma: Boolean = true): string;
begin
  result := '    ' + JsonStr(Key) + ': ' + JsonStr(Value);
  if Comma then result := result + ',';
  result := result + LF;
end;

function InfoJson(const FileName: string; r: TAbResult; const Info: TEInvoiceInfo;
  const Msgs: TAbMessages): string;
var
  i: Integer;
  a: TEInvoiceAttachment;
begin
  result := '{' + LF +
    Member('file', JsonStr(FileName)) +
    Member('result', JsonStr(ResultCodes[r])) +
    Member('container', JsonStr(ContainerCodes[Info.Container])) +
    Member('syntax', JsonStr(SyntaxCodes[Info.Syntax])) +
    Member('profile', JsonStr(ProfileCodes[Info.Profile])) +
    Member('guidelineId', JsonStr(Info.GuidelineID)) +
    Member('xrechnungVersion', JsonStr(Info.XRechnungVersion)) +
    '  "pdf": {' + LF +
    Field('version', Info.PDFVersion) +
    Field('pdfaPart', Info.PDFAPart) +
    Field('pdfaConformance', Info.PDFAConformance) +
    Field('xmpDocumentType', Info.XMPDocumentType) +
    Field('xmpDocumentFileName', Info.XMPDocumentFileName) +
    Field('xmpVersion', Info.XMPVersion) +
    Field('xmpConformanceLevel', Info.XMPConformanceLevel) +
    Field('invoiceFile', Info.InvoiceFileName, false) +
    '  },' + LF +
    '  "invoice": {' + LF +
    Field('number', Info.InvoiceNumber) +
    Field('issueDate', Info.IssueDate) +
    Field('typeCode', Info.TypeCode) +
    Field('currency', Info.Currency) +
    Field('seller', Info.SellerName) +
    Field('buyer', Info.BuyerName) +
    Field('grandTotal', Info.GrandTotal) +
    Field('duePayable', Info.DuePayable, false) +
    '  },' + LF +
    '  "attachments": [';

  for i := 0 to High(Info.Attachments) do begin
    a := Info.Attachments[i];
    if i > 0 then result := result + ',';
    result := result + LF + '    {"name": ' + JsonStr(a.Name) +
      ', "mimeType": ' + JsonStr(a.MimeType) +
      ', "relationship": ' + JsonStr(a.Relationship) +
      ', "size": ' + IntToStr(a.Size) +
      ', "inAF": ' + BoolJson(a.InAF) + '}';
  end;

  if Length(Info.Attachments) > 0 then result := result + LF + '  ';
  result := result + '],' + LF + MessageList(Msgs) + LF + '}';
end;

{ "rules": one object per rule, one per line }
function RuleList(const Rules: TAbRuleResults): string;
var
  i: Integer;
begin
  result := '  "rules": [';

  for i := 0 to High(Rules) do begin
    if i > 0 then result := result + ',';
    result := result + LF + '    {"id": ' + JsonStr(Rules[i].ID) + ', "status": ' +
      JsonStr(RuleStatusCodes[Rules[i].Status]) + ', "origin": ' + JsonStr(OriginCodes[Rules[i].Origin]) + '}';
  end;

  if Length(Rules) > 0 then result := result + LF + '  ';
  result := result + '],' + LF;
end;

function CheckJson(const FileName: string; r: TAbResult; const Inv: TEInvoice;
  const Report: TAbCheckReport; WithRules: Boolean): string;
var
  rules: string;
begin
  rules := '';
  if WithRules then rules := RuleList(Report.Rules);

  result := '{' + LF +
    Member('file', JsonStr(FileName)) +
    Member('result', JsonStr(ResultCodes[r])) +
    Member('syntax', JsonStr(SyntaxCodes[Inv.Info.Syntax])) +
    Member('profile', JsonStr(ProfileCodes[Inv.Info.Profile])) +
    Member('xrechnungVersion', JsonStr(Inv.Info.XRechnungVersion)) +
    Member('errors', IntToStr(Report.Errors)) +
    Member('warnings', IntToStr(Report.Warnings)) +
    Member('ruleSets', StrList(Report.RuleSets)) +
    Member('notChecked', StrList(Report.NotChecked)) +
    rules +
    MessageList(Report.Messages) + LF + '}';
end;

function AttachmentsJson(const FileName: string; r: TAbResult; const Files: TEInvoiceFiles;
  const Msgs: TAbMessages; WithContent: Boolean): string;
var
  i: Integer;
  f: TEInvoiceFile;
begin
  result := '{' + LF +
    Member('file', JsonStr(FileName)) +
    Member('result', JsonStr(ResultCodes[r])) +
    '  "attachments": [';

  for i := 0 to High(Files) do begin
    f := Files[i];
    if i > 0 then result := result + ',';
    result := result + LF + '    {"source": ' + JsonStr(FileSourceCodes[f.Source]) +
      ', "name": ' + JsonStr(f.Name) +
      ', "description": ' + JsonStr(f.Description) +
      ', "mimeType": ' + JsonStr(f.MimeType) +
      ', "relationship": ' + JsonStr(f.Relationship) +
      ', "id": ' + JsonStr(f.ID) +
      ', "uri": ' + JsonStr(f.URI) +
      ', "invoice": ' + BoolJson(f.IsInvoice) +
      ', "size": ' + IntToStr(Length(f.Content));
    if WithContent then result := result + ', "content": ' + JsonStr(EncodeBase64(f.Content));
    result := result + '}';
  end;

  if Length(Files) > 0 then result := result + LF + '  ';
  result := result + '],' + LF + MessageList(Msgs) + LF + '}';
end;

function MessagesJson(const AResult: string; const Msgs: TAbMessages): string;
begin
  result := '{' + LF + Member('result', JsonStr(AResult)) + MessageList(Msgs) + LF + '}';
end;

{ ===========================================================================
  JSON reader

  Recursive descent over the UTF-8 bytes. Strings are collected as bytes and
  converted once (Utf8Str). Errors raise EAbParse internally; JsonParse
  catches them and reports message, line and column.
  =========================================================================== }

const
  JsonMaxDepth = 512;

type
  TJParser = record
    b: TBytes;
    l, p: Integer;
    Line, LineStart: Integer;
    ColPos, ColNum: Integer;  // cache for ColAt: column ColNum starts at byte ColPos
    Doc: TJDoc;
    Buf: TByteBuf;
    function ColAt(q: Integer): Integer;
    procedure Fail(const Msg: string);
    procedure SkipWS;
    function NewNode(Parent: Integer; const Name: string; NameLine, NameCol: Integer): Integer;
    procedure Hex4(out Code: Integer);
    procedure AddCode(Code: Integer);
    function ReadString: string;
    procedure ReadNumber(n: Integer);
    procedure ReadLiteral(n: Integer; const Word: AnsiString; Kind: TJKind);
    procedure ReadValue(Parent: Integer; const Name: string; NameLine, NameCol, Depth: Integer);
  end;

function TJDoc.Member(n: Integer; const Name: string): Integer;
begin
  if (n < 0) or (n >= Count) or (Nodes[n].Kind <> jkObject) then exit(-1);
  result := Nodes[n].FirstChild;
  while (result >= 0) and (Nodes[result].Name <> Name) do begin
    result := Nodes[result].Next;
  end;
end;

function TJDoc.Path(n: Integer; const APath: string): Integer;
var
  s, part: string;
  i: Integer;
begin
  result := n;
  s := APath;

  while (result >= 0) and (s <> '') do begin
    i := Pos('/', s);

    if i > 0 then begin
      part := Copy(s, 1, i - 1);
      s := Copy(s, i + 1, MaxInt);
    end else begin
      part := s;
      s := '';
    end;

    result := Member(result, part);
  end;
end;

{ column of byte Q on the current line, counted in characters (UTF-8 lead
  bytes); the parser only moves forward, so the cache makes this linear }
function TJParser.ColAt(q: Integer): Integer;
begin
  if (ColPos < LineStart) or (ColPos > q) then begin
    ColPos := LineStart;
    ColNum := 1;
  end;

  while ColPos < q do begin
    if (b[ColPos] and $C0) <> $80 then Inc(ColNum);
    Inc(ColPos);
  end;

  result := ColNum;
end;

procedure TJParser.Fail(const Msg: string);
begin
  Doc.ErrorLine := Line;
  Doc.ErrorCol := ColAt(IMin(p, l));
  raise EAbParse.Create(Format('line %d, column %d: %s', [Doc.ErrorLine, Doc.ErrorCol, Msg]));
end;

procedure TJParser.SkipWS;
var
  c: Byte;
begin
  while p < l do begin
    c := b[p];

    if c = $0A then begin
      Inc(Line);
      LineStart := p + 1;
    end else if (c <> $20) and (c <> $09) and (c <> $0D) then begin
      break;
    end;

    Inc(p);
  end;
end;

function TJParser.NewNode(Parent: Integer; const Name: string; NameLine, NameCol: Integer): Integer;
begin
  result := Doc.Count;

  if result >= Length(Doc.Nodes) then begin
    SetLength(Doc.Nodes, result * 2 + 16);
  end;

  Doc.Nodes[result] := Default(TJNode);
  Doc.Nodes[result].Name := Name;
  Doc.Nodes[result].Parent := Parent;
  Doc.Nodes[result].FirstChild := -1;
  Doc.Nodes[result].LastChild := -1;
  Doc.Nodes[result].Next := -1;
  Doc.Nodes[result].Line := Line;
  Doc.Nodes[result].Col := ColAt(p);
  Doc.Nodes[result].NameLine := NameLine;
  Doc.Nodes[result].NameCol := NameCol;
  Inc(Doc.Count);

  if Parent >= 0 then begin
    if Doc.Nodes[Parent].LastChild >= 0 then begin
      Doc.Nodes[Doc.Nodes[Parent].LastChild].Next := result;
    end else begin
      Doc.Nodes[Parent].FirstChild := result;
    end;

    Doc.Nodes[Parent].LastChild := result;
  end;
end;

{ four hex digits of a \u escape, P on the first one }
procedure TJParser.Hex4(out Code: Integer);
var
  i: Integer;
begin
  Code := 0;

  for i := 1 to 4 do begin
    if (p >= l) or not IsHexDigit(b[p]) then Fail('four hex digits expected after \u');
    Code := Code * 16 + HexVal(b[p]);
    Inc(p);
  end;
end;

{ a code point as UTF-8 into Buf }
procedure TJParser.AddCode(Code: Integer);
begin
  if Code < $80 then begin
    Buf.Add(Byte(Code));
  end else if Code < $800 then begin
    Buf.Add(Byte($C0 or (Code shr 6)));
    Buf.Add(Byte($80 or (Code and $3F)));
  end else if Code < $10000 then begin
    Buf.Add(Byte($E0 or (Code shr 12)));
    Buf.Add(Byte($80 or ((Code shr 6) and $3F)));
    Buf.Add(Byte($80 or (Code and $3F)));
  end else begin
    Buf.Add(Byte($F0 or (Code shr 18)));
    Buf.Add(Byte($80 or ((Code shr 12) and $3F)));
    Buf.Add(Byte($80 or ((Code shr 6) and $3F)));
    Buf.Add(Byte($80 or (Code and $3F)));
  end;
end;

{ P on the opening quote; afterwards behind the closing quote }
function TJParser.ReadString: string;
var
  c: Byte;
  code, code2, n, i, minCode: Integer;
begin
  Buf.Clear;
  Inc(p);

  repeat
    if p >= l then Fail('unterminated string');
    c := b[p];

    if c = Ord('"') then begin
      Inc(p);
      break;
    end else if c = Ord('\') then begin
      Inc(p);
      if p >= l then Fail('unterminated string');
      c := b[p];
      Inc(p);

      case Chr(c) of
        '"', '\', '/': Buf.Add(c);
        'b': Buf.Add(8);
        'f': Buf.Add(12);
        'n': Buf.Add(10);
        'r': Buf.Add(13);
        't': Buf.Add(9);
        'u':
          begin
            Hex4(code);

            if (code >= $D800) and (code <= $DBFF) then begin
              if (p + 1 >= l) or (b[p] <> Ord('\')) or (b[p + 1] <> Ord('u')) then begin
                Fail('unpaired surrogate in \u escape');
              end;

              Inc(p, 2);
              Hex4(code2);
              if (code2 < $DC00) or (code2 > $DFFF) then Fail('unpaired surrogate in \u escape');
              code := $10000 + ((code - $D800) shl 10) + (code2 - $DC00);
            end else if (code >= $DC00) and (code <= $DFFF) then begin
              Fail('unpaired surrogate in \u escape');
            end;

            AddCode(code);
          end;
      else
        Dec(p);
        Fail('invalid escape sequence');
      end;
    end else if c < $20 then begin
      Fail('control character in string (must be escaped)');
    end else if c < $80 then begin
      Buf.Add(c);
      Inc(p);
    end else begin
      // multi-byte UTF-8: no overlong forms, no surrogates, at most U+10FFFF
      if (c >= $C2) and (c <= $DF) then begin
        n := 1;
        code := c and $1F;
        minCode := $80;
      end else if (c >= $E0) and (c <= $EF) then begin
        n := 2;
        code := c and $0F;
        minCode := $800;
      end else if (c >= $F0) and (c <= $F4) then begin
        n := 3;
        code := c and $07;
        minCode := $10000;
      end else begin
        Fail('invalid UTF-8');
        n := 0;
        minCode := 0;
        code := 0;
      end;

      for i := 1 to n do begin
        if (p + i >= l) or ((b[p + i] and $C0) <> $80) then Fail('invalid UTF-8');
        code := (code shl 6) or (b[p + i] and $3F);
      end;

      if (code < minCode) or (code > $10FFFF) or ((code >= $D800) and (code <= $DFFF)) then Fail('invalid UTF-8');

      for i := 0 to n do begin
        Buf.Add(b[p + i]);
      end;

      Inc(p, n + 1);
    end;
  until false;

  result := Utf8Str(Buf.Data, 0, Buf.Len);
end;

{ -?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?, kept as text }
procedure TJParser.ReadNumber(n: Integer);
var
  start: Integer;

  function Digit: Boolean;
  begin
    result := (p < l) and (b[p] >= Ord('0')) and (b[p] <= Ord('9'));
  end;

  procedure Digits;
  begin
    if not Digit then Fail('digit expected');

    while Digit do begin
      Inc(p);
    end;
  end;

begin
  start := p;
  if b[p] = Ord('-') then Inc(p);

  if (p < l) and (b[p] = Ord('0')) then begin
    Inc(p);
    if Digit then Fail('leading zeros are not allowed');
  end else begin
    Digits;
  end;

  if (p < l) and (b[p] = Ord('.')) then begin
    Inc(p);
    Digits;
  end;

  if (p < l) and ((b[p] = Ord('e')) or (b[p] = Ord('E'))) then begin
    Inc(p);
    if (p < l) and ((b[p] = Ord('+')) or (b[p] = Ord('-'))) then Inc(p);
    Digits;
  end;

  Doc.Nodes[n].Kind := jkNumber;
  Doc.Nodes[n].Value := Utf8Str(b, start, p - start);
end;

procedure TJParser.ReadLiteral(n: Integer; const Word: AnsiString; Kind: TJKind);
begin
  if not MatchAt(b, l, p, Word) then Fail('unexpected character');
  Inc(p, Length(Word));
  Doc.Nodes[n].Kind := Kind;
end;

procedure TJParser.ReadValue(Parent: Integer; const Name: string; NameLine, NameCol, Depth: Integer);
var
  n, nl, nc: Integer;
  memberName: string;
begin
  SkipWS;
  if p >= l then Fail('value expected');
  if Depth >= JsonMaxDepth then Fail(Format('nested deeper than %d levels', [JsonMaxDepth]));
  n := NewNode(Parent, Name, NameLine, NameCol);

  case Chr(b[p]) of
    '{':
      begin
        Doc.Nodes[n].Kind := jkObject;
        Inc(p);
        SkipWS;

        if (p < l) and (b[p] = Ord('}')) then begin
          Inc(p);
          exit;
        end;

        repeat
          SkipWS;
          if (p >= l) or (b[p] <> Ord('"')) then Fail('member name expected');
          nl := Line;
          nc := ColAt(p);
          memberName := ReadString;
          SkipWS;
          if (p >= l) or (b[p] <> Ord(':')) then Fail('":" expected');
          Inc(p);
          ReadValue(n, memberName, nl, nc, Depth + 1);
          SkipWS;
          if p >= l then Fail('"," or "}" expected');

          if b[p] = Ord('}') then begin
            Inc(p);
            break;
          end;

          if b[p] <> Ord(',') then Fail('"," or "}" expected');
          Inc(p);
        until false;
      end;
    '[':
      begin
        Doc.Nodes[n].Kind := jkArray;
        Inc(p);
        SkipWS;

        if (p < l) and (b[p] = Ord(']')) then begin
          Inc(p);
          exit;
        end;

        repeat
          ReadValue(n, '', 0, 0, Depth + 1);
          SkipWS;
          if p >= l then Fail('"," or "]" expected');

          if b[p] = Ord(']') then begin
            Inc(p);
            break;
          end;

          if b[p] <> Ord(',') then Fail('"," or "]" expected');
          Inc(p);
        until false;
      end;
    '"':
      begin
        Doc.Nodes[n].Kind := jkString;
        Doc.Nodes[n].Value := ReadString;
      end;
    '-', '0'..'9': ReadNumber(n);
    't': ReadLiteral(n, 'true', jkTrue);
    'f': ReadLiteral(n, 'false', jkFalse);
    'n': ReadLiteral(n, 'null', jkNull);
  else
    Fail('unexpected character');
  end;
end;

function JsonParse(const Data: TBytes; out Doc: TJDoc): Boolean;
var
  r: TJParser;
begin
  r := Default(TJParser);
  r.b := Data;
  r.l := Length(Data);
  r.Line := 1;
  if (r.l >= 3) and (Data[0] = $EF) and (Data[1] = $BB) and (Data[2] = $BF) then r.p := 3;
  r.LineStart := r.p;
  r.ColPos := r.p;
  r.ColNum := 1;

  try
    r.ReadValue(-1, '', 0, 0, 0);
    r.SkipWS;
    if r.p < r.l then r.Fail('unexpected content after the value');
    SetLength(r.Doc.Nodes, r.Doc.Count);
    result := true;
  except
    on e: EAbParse do begin
      r.Doc.Error := e.Message;
      r.Doc.Count := 0;
      r.Doc.Nodes := nil;
      result := false;
    end;
  end;

  Doc := r.Doc;
end;

end.
