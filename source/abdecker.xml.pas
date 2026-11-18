{ SPDX-License-Identifier: MIT
  Copyright (c) 2026 Ingo Jache }

unit abdecker.xml;

{ abdecker - minimal XML reader (internal, used by the readers).
  Not part of the public API: use the unit abdecker. }

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
{$IFDEF FPC}
  SysUtils;
{$ELSE}
  System.SysUtils;
{$ENDIF}

type
  TXAttr = record
    NS: string;
    Name: string;   // local name
    Value: string;
  end;

  TXElem = record
    NS: string;     // namespace URI
    Name: string;   // local name
    Text: string;   // concatenated character data (whitespace-only runs dropped)
    Attrs: array of TXAttr;
    Parent, FirstChild, LastChild, Next: Integer;
    StartPos: Integer;  // byte offset of the '<' of the start tag
    EndPos: Integer;    // byte offset just behind the end tag (or '/>')
  end;

  TXDoc = record
    Elems: array of TXElem;   // Elems[0] is the root element
    Count: Integer;
    Error: string;
    { namespace declarations on the root element: Name = prefix ('' for the
      default namespace), Value = URI }
    RootDecls: array of TXAttr;
    function Child(e: Integer; const Name: string): Integer;
    function Path(e: Integer; const APath: string): Integer;
    function Text(e: Integer; const APath: string): string;
    function Attr(e: Integer; const Name: string): string;
  end;

function IsXmlWS(c: Byte): Boolean;
function IsXmlNameChar(c: Byte): Boolean;
function XmlParse(const Data: TBytes; out Doc: TXDoc): Boolean;

implementation

uses
  abdecker.util;

{ ===========================================================================
  XML reader

  Minimal, non-validating, namespace aware. Builds a flat element array
  (no objects, no pointers): parent/child/sibling links are indices.
  No DTD processing, no external entities.
  =========================================================================== }


function TXDoc.Child(e: Integer; const Name: string): Integer;
begin
  if (e < 0) or (e >= Count) then exit(-1);
  result := Elems[e].FirstChild;
  while (result >= 0) and (Elems[result].Name <> Name) do begin
    result := Elems[result].Next;
  end;
end;

{ Path of local names separated by '/', relative to element E. }
function TXDoc.Path(e: Integer; const APath: string): Integer;
var
  s, part: string;
  i: Integer;
begin
  result := e;
  s := APath;
  while (s <> '') and (result >= 0) do begin
    i := Pos('/', s);
    if i = 0 then begin
      part := s;
      s := '';
    end else begin
      part := Copy(s, 1, i - 1);
      Delete(s, 1, i);
    end;

    result := Child(result, part);
  end;
end;

function TXDoc.Text(e: Integer; const APath: string): string;
var
  r: Integer;
begin
  r := Path(e, APath);
  if r >= 0 then begin
    result := Trim(Elems[r].Text);
  end else begin
    result := '';
  end;
end;

function TXDoc.Attr(e: Integer; const Name: string): string;
var
  i: Integer;
begin
  result := '';
  if (e < 0) or (e >= Count) then exit;

  for i := 0 to High(Elems[e].Attrs) do begin
    if Elems[e].Attrs[i].Name = Name then exit(Elems[e].Attrs[i].Value);
  end;
end;

function IsXmlWS(c: Byte): Boolean;
begin
  result := (c = $20) or (c = $09) or (c = $0A) or (c = $0D);
end;

function IsXmlNameChar(c: Byte): Boolean;
begin
  result := ((c >= Ord('a')) and (c <= Ord('z'))) or ((c >= Ord('A')) and (c <= Ord('Z'))) or
    ((c >= Ord('0')) and (c <= Ord('9'))) or (c = Ord('_')) or (c = Ord(':')) or
    (c = Ord('-')) or (c = Ord('.')) or (c >= $80);
end;

function XmlParse(const Data: TBytes; out Doc: TXDoc): Boolean;
var
  utf16: Boolean;
  b: TBytes;
  l, p, cur, depth, nsCount, aCount: Integer;
  nsPre, nsUri, qNames, aq, av: array of string;
  marks: array of Integer;
  buf: TByteBuf;
  rootDone: Boolean;
  s: UnicodeString;  // UTF-16 input only

  procedure Fail(const Msg: string);
  begin
    raise EAbParse.CreateFmt('%s (line %d)', [Msg, LineOf(b, p)]);
  end;

  procedure AddCodePoint(CP: Cardinal);
  begin
    if CP < $80 then begin
      buf.Add(Byte(CP));
    end else if CP < $800 then begin
      buf.Add(Byte($C0 or (CP shr 6)));
      buf.Add(Byte($80 or (CP and $3F)));
    end else if CP < $10000 then begin
      buf.Add(Byte($E0 or (CP shr 12)));
      buf.Add(Byte($80 or ((CP shr 6) and $3F)));
      buf.Add(Byte($80 or (CP and $3F)));
    end else begin
      buf.Add(Byte($F0 or (CP shr 18)));
      buf.Add(Byte($80 or ((CP shr 12) and $3F)));
      buf.Add(Byte($80 or ((CP shr 6) and $3F)));
      buf.Add(Byte($80 or (CP and $3F)));
    end;
  end;

  { at '&': decode an entity or character reference into Buf }
  procedure DecodeRef;
  var
    e, i: Integer;
    name: string;
    cp: Cardinal;
    hex: Boolean;
  begin
    e := p + 1;
    while (e < l) and (e - p < 12) and (b[e] <> Ord(';')) do begin
      Inc(e);
    end;

    if (e >= l) or (b[e] <> Ord(';')) then begin
      Fail('Invalid entity reference');
    end;

    name := Utf8Str(b, p + 1, e - p - 1);
    if name = 'lt' then buf.Add(Ord('<'))
    else if name = 'gt' then buf.Add(Ord('>'))
    else if name = 'amp' then buf.Add(Ord('&'))
    else if name = 'quot' then buf.Add(Ord('"'))
    else if name = 'apos' then buf.Add(Ord(''''))
    else if (Length(name) > 1) and (name[1] = '#') then begin
      cp := 0;
      hex := name[2] = 'x';
      if hex then i := 3 else i := 2;

      if i > Length(name) then begin
        Fail('Invalid character reference');
      end;

      while i <= Length(name) do begin
        if (name[i] >= '0') and (name[i] <= '9') then begin
          if hex then cp := cp * 16 else cp := cp * 10;
          cp := cp + Cardinal(Ord(name[i]) - Ord('0'));
        end else if hex and (name[i] >= 'a') and (name[i] <= 'f') then begin
          cp := cp * 16 + Cardinal(Ord(name[i]) - Ord('a') + 10);
        end else if hex and (name[i] >= 'A') and (name[i] <= 'F') then begin
          cp := cp * 16 + Cardinal(Ord(name[i]) - Ord('A') + 10);
        end else begin
          Fail('Invalid character reference &' + name + ';');
        end;

        if cp > $10FFFF then begin
          Fail('Invalid character reference &' + name + ';');
        end;

        Inc(i);
      end;

      AddCodePoint(cp);
    end else begin
      Fail('Unknown entity &' + name + ';');
    end;
    p := e + 1;
  end;

  procedure SkipWS;
  begin
    while (p < l) and IsXmlWS(b[p]) do begin
      Inc(p);
    end;
  end;

  function ReadName: string;
  var
    start: Integer;
  begin
    start := p;

    while (p < l) and IsXmlNameChar(b[p]) do begin
      Inc(p);
    end;

    if p = start then begin
      Fail('Name expected');
    end;

    result := Utf8Str(b, start, p - start);
  end;

  function ResolveNS(const Prefix: string): string;
  var
    i: Integer;
  begin
    if Prefix = 'xml' then exit('http://www.w3.org/XML/1998/namespace');

    for i := nsCount - 1 downto 0 do begin
      if nsPre[i] = Prefix then exit(nsUri[i]);
    end;

    result := '';
  end;

  procedure PushNS(const Prefix, Uri: string);
  begin
    if nsCount >= Length(nsPre) then begin
      SetLength(nsPre, nsCount * 2 + 8);
      SetLength(nsUri, nsCount * 2 + 8);
    end;

    nsPre[nsCount] := Prefix;
    nsUri[nsCount] := Uri;
    Inc(nsCount);
  end;

  procedure SplitQName(const q: string; out Prefix, Local: string);
  var
    i: Integer;
  begin
    i := Pos(':', q);
    if i > 0 then begin
      Prefix := Copy(q, 1, i - 1);
      Local := Copy(q, i + 1, MaxInt);
    end else begin
      Prefix := '';
      Local := q;
    end;
  end;

  function NewElem: Integer;
  begin
    if Doc.Count >= Length(Doc.Elems) then begin
      SetLength(Doc.Elems, Doc.Count * 2 + 16);
    end;

    result := Doc.Count;
    Inc(Doc.Count);
    Doc.Elems[result].Parent := -1;
    Doc.Elems[result].FirstChild := -1;
    Doc.Elems[result].LastChild := -1;
    Doc.Elems[result].Next := -1;
  end;

  procedure SkipPast(const Terminator: AnsiString; const What: string);
  var
    i: Integer;
  begin
    i := FindAt(b, l, p, Terminator);
    if i < 0 then begin
      Fail(What + ' not terminated');
    end;

    p := i + Length(Terminator);
  end;

  procedure SkipDoctype;
  var
    br: Integer;
    q: Byte;
  begin
    Inc(p, 9);
    br := 0;

    while p < l do begin
      case b[p] of
        Ord('['): Inc(br);
        Ord(']'): Dec(br);
        Ord('"'), Ord(''''):
          begin
            q := b[p];
            Inc(p);

            while (p < l) and (b[p] <> q) do begin
              Inc(p);
            end;
          end;
        Ord('>'):
          if br <= 0 then begin
            Inc(p);
            exit;
          end;
      end;

      Inc(p);
    end;

    Fail('DOCTYPE not terminated');
  end;

  procedure CData;
  var
    i: Integer;
  begin
    if cur < 0 then begin
      Fail('CDATA outside the root element');
    end;

    Inc(p, 9);
    i := FindAt(b, l, p, ']]>');
    if i < 0 then begin
      Fail('CDATA not terminated');
    end;

    Doc.Elems[cur].Text := Doc.Elems[cur].Text + Utf8Str(b, p, i - p);
    p := i + 3;
  end;

  procedure TextNode;
  var
    onlyWS: Boolean;
  begin
    buf.Clear;
    onlyWS := true;

    while (p < l) and (b[p] <> Ord('<')) do begin
      if b[p] = Ord('&') then begin
        DecodeRef;
        onlyWS := false;
      end else begin
        if not IsXmlWS(b[p]) then onlyWS := false;
        buf.Add(b[p]);
        Inc(p);
      end;
    end;

    if onlyWS then exit;

    if cur < 0 then begin
      Fail('Text outside the root element');
    end;

    Doc.Elems[cur].Text := Doc.Elems[cur].Text + Utf8Str(buf.Data, 0, buf.Len);
  end;

  procedure StartTag;
  var
    q, pre, loc: string;
    e, i, n, mark, start: Integer;
    selfClose: Boolean;
    quote: Byte;
  begin
    if rootDone then begin
      Fail('More than one root element');
    end;

    start := p;
    Inc(p);
    q := ReadName;
    aCount := 0;
    selfClose := false;

    while true do begin
      SkipWS;

      if p >= l then begin
        Fail('Unexpected end of file');
      end;

      if b[p] = Ord('>') then begin
        Inc(p);
        break;
      end;

      if (b[p] = Ord('/')) and (p + 1 < l) and (b[p + 1] = Ord('>')) then begin
        Inc(p, 2);
        selfClose := true;
        break;
      end;

      if aCount >= Length(aq) then begin
        SetLength(aq, aCount * 2 + 4);
        SetLength(av, aCount * 2 + 4);
      end;

      aq[aCount] := ReadName;
      SkipWS;

      if (p >= l) or (b[p] <> Ord('=')) then begin
        Fail('"=" expected');
      end;

      Inc(p);
      SkipWS;

      if (p >= l) or ((b[p] <> Ord('"')) and (b[p] <> Ord(''''))) then begin
        Fail('Attribute value expected');
      end;

      quote := b[p];
      Inc(p);
      buf.Clear;

      while (p < l) and (b[p] <> quote) do begin
        if b[p] = Ord('<') then begin
          Fail('"<" in attribute value');
        end;

        if b[p] = Ord('&') then begin
          DecodeRef;
        end else begin
          if IsXmlWS(b[p]) then begin
            buf.Add($20);
          end else begin
            buf.Add(b[p]);
          end;

          Inc(p);
        end;
      end;

      if p >= l then begin
        Fail('Unexpected end of file');
      end;

      Inc(p);
      av[aCount] := Utf8Str(buf.Data, 0, buf.Len);
      Inc(aCount);
    end;

    mark := nsCount;

    for i := 0 to aCount - 1 do begin
      if aq[i] = 'xmlns' then begin
        PushNS('', av[i]);
      end else if Copy(aq[i], 1, 6) = 'xmlns:' then begin
        PushNS(Copy(aq[i], 7, MaxInt), av[i]);
      end;
    end;

    e := NewElem;
    Doc.Elems[e].StartPos := start;

    if e = 0 then begin
      for i := 0 to aCount - 1 do begin
        if (aq[i] = 'xmlns') or (Copy(aq[i], 1, 6) = 'xmlns:') then begin
          SetLength(Doc.RootDecls, Length(Doc.RootDecls) + 1);
          Doc.RootDecls[High(Doc.RootDecls)].Name := Copy(aq[i], 7, MaxInt);
          Doc.RootDecls[High(Doc.RootDecls)].Value := av[i];
        end;
      end;
    end;

    SplitQName(q, pre, loc);
    Doc.Elems[e].Name := loc;
    Doc.Elems[e].NS := ResolveNS(pre);
    SetLength(Doc.Elems[e].Attrs, aCount);
    n := 0;

    for i := 0 to aCount - 1 do begin
      if (aq[i] <> 'xmlns') and (Copy(aq[i], 1, 6) <> 'xmlns:') then begin
        SplitQName(aq[i], pre, loc);
        Doc.Elems[e].Attrs[n].Name := loc;
        if pre <> '' then Doc.Elems[e].Attrs[n].NS := ResolveNS(pre);
        Doc.Elems[e].Attrs[n].Value := av[i];
        Inc(n);
      end;
    end;

    SetLength(Doc.Elems[e].Attrs, n);

    Doc.Elems[e].Parent := cur;

    if cur >= 0 then begin
      if Doc.Elems[cur].LastChild >= 0 then begin
        Doc.Elems[Doc.Elems[cur].LastChild].Next := e;
      end else begin
        Doc.Elems[cur].FirstChild := e;
      end;

      Doc.Elems[cur].LastChild := e;
    end;

    if selfClose then begin
      Doc.Elems[e].EndPos := p;
      nsCount := mark;
      if cur < 0 then rootDone := true;
    end else begin
      if depth >= Length(qNames) then begin
        SetLength(qNames, depth * 2 + 8);
        SetLength(marks, depth * 2 + 8);
      end;

      qNames[depth] := q;
      marks[depth] := mark;
      Inc(depth);
      cur := e;
    end;
  end;

  procedure EndTag;
  var
    q: string;
  begin
    Inc(p, 2);
    q := ReadName;
    SkipWS;

    if (p >= l) or (b[p] <> Ord('>')) then begin
      Fail('">" expected');
    end;

    Inc(p);

    if depth = 0 then begin
      Fail('End tag </' + q + '> without start tag');
    end;

    if qNames[depth - 1] <> q then begin
      Fail('End tag </' + q + '> does not match <' + qNames[depth - 1] + '>');
    end;

    Dec(depth);
    nsCount := marks[depth];
    Doc.Elems[cur].EndPos := p;
    cur := Doc.Elems[cur].Parent;
    if depth = 0 then rootDone := true;
  end;

begin
  Doc := Default(TXDoc);
  result := false;

  // UTF-16 input (with BOM) is converted to UTF-8 first
  utf16 := (Length(Data) >= 2) and (((Data[0] = $FF) and (Data[1] = $FE)) or
    ((Data[0] = $FE) and (Data[1] = $FF)));

  if utf16 then begin
    if Data[0] = $FF then begin
      s := TEncoding.Unicode.GetString(Data, 2, Length(Data) - 2);
    end else begin
      s := TEncoding.BigEndianUnicode.GetString(Data, 2, Length(Data) - 2);
    end;

    b := TEncoding.UTF8.GetBytes(s);
  end else begin
    b := Data;
  end;

  l := Length(b);
  p := 0;
  if (l >= 3) and (b[0] = $EF) and (b[1] = $BB) and (b[2] = $BF) then p := 3;
  cur := -1;
  depth := 0;
  nsCount := 0;
  aCount := 0;
  rootDone := false;
  buf.Clear;

  try
    while p < l do begin
      if b[p] = Ord('<') then begin
        if MatchAt(b, l, p, '<?') then begin
          SkipPast('?>', 'Processing instruction');
        end else if MatchAt(b, l, p, '<!--') then begin
          SkipPast('-->', 'Comment');
        end else if MatchAt(b, l, p, '<![CDATA[') then begin
          CData;
        end else if MatchAt(b, l, p, '<!DOCTYPE') then begin
          SkipDoctype;
        end else if MatchAt(b, l, p, '</') then begin
          EndTag;
        end else begin
          StartTag;
        end;
      end else begin
        TextNode;
      end;
    end;

    if depth > 0 then begin
      Fail('Unexpected end of file, <' + qNames[depth - 1] + '> is not closed');
    end;

    if Doc.Count = 0 then begin
      Fail('No XML element found');
    end;

    result := true;
  except
    on e: EAbParse do
      Doc.Error := e.Message;
  end;
end;

end.
