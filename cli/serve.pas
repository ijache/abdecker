{ SPDX-License-Identifier: MIT
  Copyright (c) 2026 Ingo Jache }

unit serve;

{ abdecker - "abdecker serve": the routes of the REST/JSON server. Each route
  takes the request body (or multipart parts), calls TAbdecker and answers
  with the JSON of the lib or the resulting file. The HTTP server itself is
  http.

  Status: 200 result, 422 no/invalid invoice or rejected, 400/404/405 bad
  request, 408/411/413/503 from the server, 500 internal. /check answers 200
  even with findings: the result is the report. Errors: JSON with "result"
  and "messages". Binary results carry their messages in
  the header X-Abdecker-Messages (compact JSON, ASCII, shortened if needed). }

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  http;

{ Serves until the process ends; returns the exit code if it cannot start.
  TestRoutes: adds /test/raise and /test/sleep?ms=n (for the tests of the server). }
function RunServer(const Opt: THttpOptions; TestRoutes: Boolean): Integer;

implementation

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  abdecker;

const
  ContentJson = 'application/json; charset=utf-8';
  ContentXml = 'application/xml';
  ContentPdf = 'application/pdf';
  ContentHtml = 'text/html; charset=utf-8';
  HtmlCsp = 'default-src ''none''; style-src ''unsafe-inline''; img-src data:';
  MaxMessageHeader = 4096;

  { Swagger UI from a CDN: the browser loads it, the server loads nothing }
  DocsHtml =
    '<!DOCTYPE html>'#10 +
    '<html lang="en"><head><meta charset="utf-8"><title>abdecker API</title>'#10 +
    '<meta name="viewport" content="width=device-width, initial-scale=1">'#10 +
    '<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/swagger-ui-dist@5/swagger-ui.css">'#10 +
    '</head><body><div id="swagger-ui"></div>'#10 +
    '<script src="https://cdn.jsdelivr.net/npm/swagger-ui-dist@5/swagger-ui-bundle.js"></script>'#10 +
    '<script>window.onload = function () { SwaggerUIBundle({url: "openapi.json", dom_id: "#swagger-ui"}); };</script>'#10 +
    '</body></html>'#10;
  DocsCsp = 'default-src ''none''; script-src https://cdn.jsdelivr.net ''unsafe-inline''; ' +
    'style-src https://cdn.jsdelivr.net ''unsafe-inline''; img-src data: https://cdn.jsdelivr.net; connect-src ''self''';

{$I openapi.inc}

var
  WithTestRoutes: Boolean;   // set once before the server starts

function Utf8(const s: string): TBytes;
begin
{$IFDEF FPC}
  SetLength(result, Length(s));
  if Length(s) > 0 then Move(s[1], result[0], Length(s));
{$ELSE}
  result := TEncoding.UTF8.GetBytes(s);
{$ENDIF}
end;

function Msg(Sev: TAbSeverity; const Code, Text: string): TAbMessages;
begin
  SetLength(result, 1);
  result[0].Severity := Sev;
  result[0].Code := Code;
  result[0].Text := Text;
  result[0].Origin := aboFile;
end;

function HttpResultWord(Status: Integer): string;
begin
  case Status of
    400: result := 'bad-request';
    404: result := 'not-found';
    405: result := 'method-not-allowed';
    408: result := 'timeout';
    411: result := 'length-required';
    413: result := 'too-large';
    503: result := 'busy';
  else
    result := 'internal-error';
  end;
end;

{ Error answer of the server or of the routing (not of the lib) }
procedure HttpError(Status: Integer; const Code, Text: string; var Resp: THttpResponse);
begin
  Resp.Status := Status;
  Resp.ContentType := ContentJson;
  Resp.Body := Utf8(TAbdecker.MessagesToJson(HttpResultWord(Status), Msg(abError, Code, Text)));
end;

function StatusFor(r: TAbResult): Integer;
begin
  case r of
    abOK: result := 200;
    abNoInvoice, abUnknownFormat, abBrokenPDF, abBrokenXML, abEncrypted, abUnsupported, abInvalidData:
      result := 422;
  else
    result := 500;
  end;
end;

procedure LibError(r: TAbResult; const Msgs: TAbMessages; var Resp: THttpResponse);
begin
  Resp.Status := StatusFor(r);
  Resp.ContentType := ContentJson;
  Resp.Body := Utf8(TAbdecker.MessagesToJson(r, Msgs));
end;

{ JSON on one line, ASCII only (non-ASCII as \uXXXX): fit for a header.
  Line breaks of the lib's JSON only ever separate members, inside strings
  they are escaped, so dropping them with the indentation is safe. }
function CompactAscii(const Json: string): string;
var
  i: Integer;
  c: WideChar;
  u: UnicodeString;  // UTF-16 code units, so that \uXXXX is right under FPC (string = UTF-8) too
  sb: TStringBuilder;
begin
{$IFDEF FPC}
  u := UTF8Decode(Json);
{$ELSE}
  u := Json;
{$ENDIF}
  sb := TStringBuilder.Create;

  try
    i := 1;
    while i <= Length(u) do begin
      c := u[i];
      if c = #10 then begin
        Inc(i);

        while (i <= Length(u)) and (u[i] = ' ') do begin
          Inc(i);
        end;

        continue;
      end;

      if Ord(c) > 126 then begin
        sb.Append('\u' + LowerCase(IntToHex(Ord(c), 4)));
      end else begin
        sb.Append(Char(Ord(c)));
      end;

      Inc(i);
    end;

    result := sb.ToString;
  finally
    sb.Free;
  end;
end;

{ X-Abdecker-Messages for binary results; shortened to the first messages
  that fit, then marked with "truncated": true }
procedure AddMessageHeader(r: TAbResult; const Msgs: TAbMessages; var Resp: THttpResponse);
var
  n: Integer;
  s: string;
begin
  if Length(Msgs) = 0 then exit;
  n := Length(Msgs);
  s := CompactAscii(TAbdecker.MessagesToJson(r, Msgs));
  while (Length(s) > MaxMessageHeader) and (n > 0) do begin
    Dec(n);
    s := '{"truncated": true,' + Copy(CompactAscii(TAbdecker.MessagesToJson(r, Copy(Msgs, 0, n))), 2, MaxInt);
  end;

  AddHeader(Resp.Headers, 'X-Abdecker-Messages', s);
end;

procedure FileResult(r: TAbResult; const Msgs: TAbMessages; const Data: TBytes; const ContentType: string;
  var Resp: THttpResponse);
begin
  if r <> abOK then begin
    LibError(r, Msgs, Resp);
    exit;
  end;

  Resp.Status := 200;
  Resp.ContentType := ContentType;
  Resp.Body := Data;
  AddMessageHeader(r, Msgs, Resp);
end;

function FindPart(const Parts: THttpParts; const Name: string; out Part: THttpPart): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(Parts) do begin
    if Parts[i].Name = Name then begin
      Part := Parts[i];
      exit(true);
    end;
  end;

  result := false;
end;

{ ---- routes ---- }

procedure RouteVersion(var Resp: THttpResponse);
begin
  Resp.ContentType := ContentJson;
  Resp.Body := Utf8('{"version": "' + AbdeckerVersion + '", "author": "' + AbdeckerAuthor +
    '", "repository": "' + AbdeckerRepo + '", "homepage": "' + AbdeckerHome + '"}');
end;

{ data/openapi.json, built in by tools/gen-data.py (cli/openapi.inc) }
procedure RouteOpenApi(var Resp: THttpResponse);
begin
  Resp.ContentType := ContentJson;
  Resp.Body := Utf8(StringReplace(OpenApiJson, '{{version}}', AbdeckerVersion, []));
end;

procedure RouteDocs(var Resp: THttpResponse);
begin
  Resp.ContentType := ContentHtml;
  Resp.Body := Utf8(DocsHtml);
  AddHeader(Resp.Headers, 'Content-Security-Policy', DocsCsp);
end;

procedure RouteInfo(const Req: THttpRequest; var Resp: THttpResponse);
var
  info: TEInvoiceInfo;
  msgs: TAbMessages;
  r: TAbResult;
begin
  r := TAbdecker.InfoFromBytes(Req.Body, info, msgs);
  Resp.Status := StatusFor(r);
  Resp.ContentType := ContentJson;
  Resp.Body := Utf8(TAbdecker.InfoToJson('', r, info, msgs));
end;

procedure RouteCheck(const Req: THttpRequest; var Resp: THttpResponse);
var
  inv: TEInvoice;
  rep: TAbCheckReport;
  r: TAbResult;
  verbose: string;
begin
  if not QueryParam(Req.Query, 'verbose', verbose) or (verbose = '') then verbose := '0';

  if (verbose <> '0') and (verbose <> '1') then begin
    HttpError(400, 'HTTP-BAD-REQUEST', 'verbose must be 0 or 1', Resp);
    exit;
  end;

  r := TAbdecker.CheckBytes(Req.Body, inv, rep);
  Resp.Status := StatusFor(r);
  Resp.ContentType := ContentJson;
  Resp.Body := Utf8(TAbdecker.CheckToJson('', r, inv, rep, verbose = '1'));
end;

procedure RouteExtract(const Req: THttpRequest; var Resp: THttpResponse);
var
  xml: TBytes;
  xmlName: string;
  msgs: TAbMessages;
  r: TAbResult;
begin
  r := TAbdecker.ExtractXMLFromBytes(Req.Body, xml, xmlName, msgs);
  FileResult(r, msgs, xml, ContentXml, Resp);

  if r = abOK then begin
    AddHeader(Resp.Headers, 'Content-Disposition', 'attachment; filename="' + xmlName + '"');
  end;
end;

procedure RouteHtml(const Req: THttpRequest; var Resp: THttpResponse);
var
  inv: TEInvoice;
  msgs: TAbMessages;
  r: TAbResult;
  lang, chk, pay: string;
begin
  if not QueryParam(Req.Query, 'lang', lang) or (lang = '') then lang := 'de';

  if (lang <> 'de') and (lang <> 'en') then begin
    HttpError(400, 'HTTP-BAD-REQUEST', 'lang must be de or en', Resp);
    exit;
  end;

  if not QueryParam(Req.Query, 'check', chk) or (chk = '') then chk := '1';

  if (chk <> '0') and (chk <> '1') then begin
    HttpError(400, 'HTTP-BAD-REQUEST', 'check must be 0 or 1', Resp);
    exit;
  end;

  if not QueryParam(Req.Query, 'payment', pay) or (pay = '') then pay := '0';

  if (pay <> '0') and (pay <> '1') then begin
    HttpError(400, 'HTTP-BAD-REQUEST', 'payment must be 0 or 1', Resp);
    exit;
  end;

  r := TAbdecker.LoadFromBytes(Req.Body, inv, msgs);
  if r <> abOK then begin
    LibError(r, msgs, Resp);
    exit;
  end;

  FileResult(r, msgs, Utf8(TAbdecker.ToHtml(inv, lang, chk = '1', pay = '1')), ContentHtml, Resp);
  AddHeader(Resp.Headers, 'Content-Security-Policy', HtmlCsp);
end;

procedure RouteJson(const Req: THttpRequest; var Resp: THttpResponse);
var
  inv: TEInvoice;
  msgs: TAbMessages;
  r: TAbResult;
begin
  r := TAbdecker.LoadFromBytes(Req.Body, inv, msgs);
  Resp.Status := StatusFor(r);
  Resp.ContentType := ContentJson;
  Resp.Body := Utf8(TAbdecker.InvoiceToJson('', r, inv, msgs));
end;

procedure RouteStrip(const Req: THttpRequest; var Resp: THttpResponse);
var
  pdf: TBytes;
  xmlName: string;
  msgs: TAbMessages;
  r: TAbResult;
begin
  r := TAbdecker.StripBytes(Req.Body, pdf, xmlName, msgs);
  FileResult(r, msgs, pdf, ContentPdf, Resp);
end;

procedure RouteEmbed(const Req: THttpRequest; var Resp: THttpResponse);
var
  badParts: Boolean;
  parts: THttpParts;
  pdfPart, xmlPart: THttpPart;
  pdf: TBytes;
  msgs: TAbMessages;
  r: TAbResult;
begin
  badParts := not ParseMultipart(Req, parts) or not FindPart(parts, 'pdf', pdfPart) or
    not FindPart(parts, 'xml', xmlPart);

  if badParts then begin
    HttpError(400, 'HTTP-BAD-REQUEST', 'multipart/form-data with the parts "pdf" and "xml" expected', Resp);
    exit;
  end;

  r := TAbdecker.EmbedBytes(pdfPart.Data, xmlPart.Data, pdf, msgs);
  FileResult(r, msgs, pdf, ContentPdf, Resp);
end;

procedure RouteAttach(const Req: THttpRequest; var Resp: THttpResponse);
var
  parts: THttpParts;
  xmlPart: THttpPart;
  docs: TEInvoiceDocuments;
  res: TBytes;
  msgs: TAbMessages;
  r: TAbResult;
  i: Integer;
begin
  if not ParseMultipart(Req, parts) or not FindPart(parts, 'xml', xmlPart) then begin
    HttpError(400, 'HTTP-BAD-REQUEST', 'multipart/form-data with the part "xml" and one or more parts "file" expected', Resp);
    exit;
  end;

  docs := nil;

  for i := 0 to High(parts) do begin
    if parts[i].Name = 'file' then begin
      if parts[i].FileName = '' then begin
        HttpError(400, 'HTTP-BAD-REQUEST', 'every part "file" needs a file name', Resp);
        exit;
      end;

      SetLength(docs, Length(docs) + 1);
      docs[High(docs)] := Default(TEInvoiceDocument);
      docs[High(docs)].FileName := parts[i].FileName;
      docs[High(docs)].Content := parts[i].Data;
    end;
  end;

  if Length(docs) = 0 then begin
    HttpError(400, 'HTTP-BAD-REQUEST', 'at least one part "file" expected', Resp);
    exit;
  end;

  r := TAbdecker.AttachBytes(xmlPart.Data, docs, res, msgs);
  FileResult(r, msgs, res, ContentXml, Resp);
end;

procedure RouteAttachments(const Req: THttpRequest; var Resp: THttpResponse);
var
  files: TEInvoiceFiles;
  msgs: TAbMessages;
  r: TAbResult;
  content: string;
begin
  if not QueryParam(Req.Query, 'content', content) or (content = '') then content := '0';

  if (content <> '0') and (content <> '1') then begin
    HttpError(400, 'HTTP-BAD-REQUEST', 'content must be 0 or 1', Resp);
    exit;
  end;

  r := TAbdecker.AttachmentsFromBytes(Req.Body, files, msgs);
  Resp.Status := StatusFor(r);
  Resp.ContentType := ContentJson;
  Resp.Body := Utf8(TAbdecker.AttachmentsToJson('', r, files, msgs, content = '1'));
end;

{ Body: the invoice in the own JSON format; every query parameter is a
  placeholder value (today=2026-11-14 overrides the date of the server).
  The XML comes even with check findings, they are in X-Abdecker-Messages. }
procedure RouteCreate(const Req: THttpRequest; var Resp: THttpResponse);
var
  opt: TAbJsonOptions;
  pairs: THttpStrings;
  inv: TEInvoice;
  msgs: TAbMessages;
  rep: TAbCheckReport;
  xml: TBytes;
  r: TAbResult;
  i: Integer;
begin
  opt := Default(TAbJsonOptions);
  pairs := QueryPairs(Req.Query);
  SetLength(opt.Vars, Length(pairs));

  for i := 0 to High(pairs) do begin
    opt.Vars[i] := pairs[i];
  end;

  r := TAbdecker.InvoiceFromJson(Req.Body, opt, inv, msgs);

  if r <> abOK then begin
    LibError(r, msgs, Resp);
    exit;
  end;

  r := TAbdecker.WriteCII(inv, xml, rep);
  FileResult(r, rep.Messages, xml, ContentXml, Resp);
end;

procedure HandleRequest(const Req: THttpRequest; var Resp: THttpResponse);
var
  unknown: Boolean;
  p, method: string;
  isGet: Boolean;
begin
  p := Req.Path;
  method := UpperCase(Req.Method);
  isGet := (p = '/version') or (p = '/openapi.json') or (p = '/docs');
  unknown := not isGet and (p <> '/info') and (p <> '/check') and (p <> '/extract') and (p <> '/html') and
    (p <> '/json') and (p <> '/strip') and (p <> '/embed') and (p <> '/attach') and (p <> '/attachments') and (p <> '/create') and
    not (WithTestRoutes and ((p = '/test/raise') or (p = '/test/sleep')));

  if unknown then begin
    HttpError(404, 'HTTP-NOT-FOUND', 'Unknown route ' + p, Resp);
    exit;
  end;

  if (isGet and (method <> 'GET')) or (not isGet and (method <> 'POST')) then begin
    if isGet then begin
      method := 'GET';
    end else begin
      method := 'POST';
    end;

    HttpError(405, 'HTTP-METHOD', 'Use ' + method + ' for ' + p, Resp);
    AddHeader(Resp.Headers, 'Allow', method);
    exit;
  end;

  Resp.Status := 200;

  if p = '/version' then begin
    RouteVersion(Resp);
  end else if p = '/openapi.json' then begin
    RouteOpenApi(Resp);
  end else if p = '/docs' then begin
    RouteDocs(Resp);
  end else if p = '/info' then begin
    RouteInfo(Req, Resp);
  end else if p = '/check' then begin
    RouteCheck(Req, Resp);
  end else if p = '/extract' then begin
    RouteExtract(Req, Resp);
  end else if p = '/html' then begin
    RouteHtml(Req, Resp);
  end else if p = '/json' then begin
    RouteJson(Req, Resp);
  end else if p = '/strip' then begin
    RouteStrip(Req, Resp);
  end else if p = '/embed' then begin
    RouteEmbed(Req, Resp);
  end else if p = '/attach' then begin
    RouteAttach(Req, Resp);
  end else if p = '/attachments' then begin
    RouteAttachments(Req, Resp);
  end else if p = '/create' then begin
    RouteCreate(Req, Resp);
  end else if p = '/test/raise' then begin
    raise Exception.Create('test exception');
  end else if p = '/test/sleep' then begin
    if QueryParam(Req.Query, 'ms', method) then begin
      Sleep(StrToIntDef(method, 0));
    end;

    RouteVersion(Resp);
  end;
end;

function RunServer(const Opt: THttpOptions; TestRoutes: Boolean): Integer;
var
  err: string;
  o: THttpOptions;
begin
  WithTestRoutes := TestRoutes;
  o := Opt;
  o.Banner := Format('abdecker %s serving on http://%s:%d (%d workers, queue %d, max %d MB, timeout %d s); Ctrl+C stops',
    [AbdeckerVersion, o.Host, o.Port, o.Workers, o.QueueSize, o.MaxBody div (1024 * 1024), o.TimeoutMs div 1000]);

  if not HttpServe(o, HandleRequest, HttpError, err) then begin
    Writeln(ErrOutput, 'Error: ', err);
    exit(2);
  end;

  result := 0;
end;

end.
