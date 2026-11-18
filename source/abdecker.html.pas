{ SPDX-License-Identifier: MIT
  Copyright (c) 2026 Ingo Jache }

unit abdecker.html;

{ abdecker - invoice as a standalone HTML page (internal). Not part of the
  public API: use the unit abdecker.

  One file, CSS inside, no JavaScript. The content comes from strangers, so:
    - every text is escaped
    - a Content-Security-Policy forbids scripts and any loading from outside
    - attachments are offered as data URIs with an allowed MIME type only,
      external links only for http(s)
  Labels in German or English.

  Payment: what is to be paid (abdecker.payment) right below the totals; for
  a credit transfer like a transfer form, with a GiroCode as inline SVG and
  the values to copy marked with user-select: all (one click selects the
  whole value, no script needed). PaymentOnly: a page with just that. }

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

function InvoiceHtml(const Inv: TEInvoice; const Rep: TAbCheckReport; WithCheck: Boolean;
  const Lang: string; PaymentOnly: Boolean): string;

implementation

uses
{$IFDEF FPC}
  StrUtils,
{$ELSE}
  System.StrUtils,
{$ENDIF}
  abdecker.util, abdecker.payment, abdecker.qr;

type
  TLabel = record
    Key, De, En: string;
  end;

const
  Labels: array[0..117] of TLabel = (
    (Key: 'recipient'; De: 'Empfänger'; En: 'Recipient'),
    (Key: 'lines'; De: 'Positionen'; En: 'Lines'),
    (Key: 'seller'; De: 'Verkäufer'; En: 'Seller'),
    (Key: 'buyer'; De: 'Käufer'; En: 'Buyer'),
    (Key: 'payee'; De: 'Zahlungsempfänger'; En: 'Payee'),
    (Key: 'taxrep'; De: 'Steuervertreter'; En: 'Tax representative'),
    (Key: 'delivery'; De: 'Lieferung'; En: 'Delivery'),
    (Key: 'deliverto'; De: 'Lieferanschrift'; En: 'Deliver to'),
    (Key: 'number'; De: 'Rechnungsnummer'; En: 'Invoice number'),
    (Key: 'issuedate'; De: 'Rechnungsdatum'; En: 'Issue date'),
    (Key: 'duedate'; De: 'Fällig am'; En: 'Due date'),
    (Key: 'taxpoint'; De: 'Steuerlich maßgebliches Datum'; En: 'VAT point date'),
    (Key: 'currency'; De: 'Währung'; En: 'Currency'),
    (Key: 'taxcurrency'; De: 'Währung der Steuer'; En: 'VAT currency'),
    (Key: 'buyerref'; De: 'Käuferreferenz / Leitweg-ID'; En: 'Buyer reference'),
    (Key: 'orderref'; De: 'Bestellnummer'; En: 'Purchase order'),
    (Key: 'salesorder'; De: 'Auftragsnummer'; En: 'Sales order'),
    (Key: 'contract'; De: 'Vertrag'; En: 'Contract'),
    (Key: 'project'; De: 'Projekt'; En: 'Project'),
    (Key: 'despatch'; De: 'Lieferschein'; En: 'Despatch advice'),
    (Key: 'receiving'; De: 'Wareneingang'; En: 'Receiving advice'),
    (Key: 'tender'; De: 'Vergabe / Los'; En: 'Tender or lot'),
    (Key: 'object'; De: 'Abrechnungsobjekt'; En: 'Invoiced object'),
    (Key: 'accounting'; De: 'Buchungsreferenz'; En: 'Accounting reference'),
    (Key: 'period'; De: 'Leistungszeitraum'; En: 'Invoicing period'),
    (Key: 'deliverydate'; De: 'Liefer-/Leistungsdatum'; En: 'Delivery date'),
    (Key: 'preceding'; De: 'Bezug auf Rechnung'; En: 'Preceding invoice'),
    (Key: 'of'; De: 'vom'; En: 'of'),
    (Key: 'vatid'; De: 'USt-IdNr.'; En: 'VAT ID'),
    (Key: 'taxno'; De: 'Steuernummer'; En: 'Tax number'),
    (Key: 'legalid'; De: 'Register'; En: 'Registration'),
    (Key: 'id'; De: 'Kennung'; En: 'Identifier'),
    (Key: 'email'; De: 'E-Mail'; En: 'Email'),
    (Key: 'phone'; De: 'Telefon'; En: 'Phone'),
    (Key: 'contact'; De: 'Kontakt'; En: 'Contact'),
    (Key: 'eaddress'; De: 'Elektronische Adresse'; En: 'Electronic address'),
    (Key: 'legalinfo'; De: 'Rechtliche Angaben'; En: 'Legal information'),
    (Key: 'location'; De: 'Lieferort'; En: 'Location'),
    (Key: 'pos'; De: 'Pos.'; En: 'No.'),
    (Key: 'item'; De: 'Bezeichnung'; En: 'Description'),
    (Key: 'qty'; De: 'Menge'; En: 'Quantity'),
    (Key: 'price'; De: 'Einzelpreis'; En: 'Unit price'),
    (Key: 'vat'; De: 'USt'; En: 'VAT'),
    (Key: 'net'; De: 'Netto'; En: 'Net'),
    (Key: 'per'; De: 'je'; En: 'per'),
    (Key: 'gross'; De: 'Bruttopreis'; En: 'Gross price'),
    (Key: 'discount'; De: 'Rabatt'; En: 'Discount'),
    (Key: 'allowance'; De: 'Abschlag'; En: 'Allowance'),
    (Key: 'charge'; De: 'Zuschlag'; En: 'Charge'),
    (Key: 'allowcharge'; De: 'Ab- und Zuschläge'; En: 'Allowances and charges'),
    (Key: 'linetotal'; De: 'Summe Positionen'; En: 'Sum of lines'),
    (Key: 'allowancetotal'; De: 'Summe Abschläge'; En: 'Allowances'),
    (Key: 'chargetotal'; De: 'Summe Zuschläge'; En: 'Charges'),
    (Key: 'taxexclusive'; De: 'Gesamt netto'; En: 'Total without VAT'),
    (Key: 'taxtotal'; De: 'Umsatzsteuer'; En: 'VAT'),
    (Key: 'taxtotalcur'; De: 'Umsatzsteuer in Steuerwährung'; En: 'VAT in VAT currency'),
    (Key: 'taxinclusive'; De: 'Gesamt brutto'; En: 'Total with VAT'),
    (Key: 'prepaid'; De: 'Bereits gezahlt'; En: 'Paid amount'),
    (Key: 'rounding'; De: 'Rundung'; En: 'Rounding'),
    (Key: 'duepayable'; De: 'Zahlbetrag'; En: 'Amount due'),
    (Key: 'vatbreakdown'; De: 'Umsatzsteuer'; En: 'VAT breakdown'),
    (Key: 'category'; De: 'Kategorie'; En: 'Category'),
    (Key: 'rate'; De: 'Satz'; En: 'Rate'),
    (Key: 'taxable'; De: 'Bemessungsgrundlage'; En: 'Taxable amount'),
    (Key: 'taxamount'; De: 'Steuer'; En: 'Tax'),
    (Key: 'exemption'; De: 'Befreiungsgrund'; En: 'Exemption reason'),
    (Key: 'payment'; De: 'Zahlung'; En: 'Payment'),
    (Key: 'means'; De: 'Zahlungsart'; En: 'Payment means'),
    (Key: 'account'; De: 'Konto (IBAN)'; En: 'Account (IBAN)'),
    (Key: 'bic'; De: 'BIC'; En: 'BIC'),
    (Key: 'accountname'; De: 'Kontoinhaber'; En: 'Account name'),
    (Key: 'remittance'; De: 'Verwendungszweck'; En: 'Remittance information'),
    (Key: 'terms'; De: 'Zahlungsbedingungen'; En: 'Payment terms'),
    (Key: 'card'; De: 'Karte'; En: 'Card'),
    (Key: 'mandate'; De: 'Mandatsreferenz'; En: 'Mandate reference'),
    (Key: 'creditor'; De: 'Gläubiger-ID'; En: 'Creditor ID'),
    (Key: 'debited'; De: 'Belastetes Konto'; En: 'Debited account'),
    (Key: 'notes'; De: 'Bemerkungen'; En: 'Notes'),
    (Key: 'documents'; De: 'Anhänge'; En: 'Attachments'),
    (Key: 'download'; De: 'herunterladen'; En: 'download'),
    (Key: 'unmapped'; De: 'Weitere Angaben (außerhalb der EN 16931)'; En: 'Further data (outside EN 16931)'),
    (Key: 'check'; De: 'Prüfung'; En: 'Check'),
    (Key: 'checkok'; De: 'Keine Fehler gefunden'; En: 'No errors found'),
    (Key: 'errors'; De: 'Fehler'; En: 'error(s)'),
    (Key: 'warnings'; De: 'Warnungen'; En: 'warning(s)'),
    (Key: 'notchecked'; De: 'Nicht geprüft'; En: 'Not checked'),
    (Key: 'extra'; De: 'zusätzliche Prüfung'; En: 'extra check'),
    (Key: 'technical'; De: 'Technische Angaben'; En: 'Technical details'),
    (Key: 'syntax'; De: 'Syntax'; En: 'Syntax'),
    (Key: 'profile'; De: 'Profil'; En: 'Profile'),
    (Key: 'spec'; De: 'Spezifikation (BT-24)'; En: 'Specification (BT-24)'),
    (Key: 'process'; De: 'Geschäftsprozess (BT-23)'; En: 'Business process (BT-23)'),
    (Key: 'container'; De: 'Container'; En: 'Container'),
    (Key: 'pdfattach'; De: 'Anhänge im PDF'; En: 'Files in the PDF'),
    (Key: 'created'; De: 'Dargestellt mit'; En: 'Rendered by'),
    (Key: 'by'; De: 'von'; En: 'by'),
    (Key: 'sellerid'; De: 'Art.-Nr.'; En: 'Item no.'),
    (Key: 'buyeritem'; De: 'Käufer-Art.-Nr.'; En: 'Buyer item no.'),
    (Key: 'origin'; De: 'Herkunft'; En: 'Origin'),
    (Key: 'orderline'; De: 'Bestellposition'; En: 'Order line'),
    (Key: 'amount'; De: 'Betrag'; En: 'Amount'),
    (Key: 'skonto'; De: 'Skonto'; En: 'Cash discount'),
    (Key: 'until'; De: 'bis'; En: 'until'),
    (Key: 'days'; De: 'Tage'; En: 'days'),
    (Key: 'scan'; De: 'Mit der Banking-App scannen'; En: 'Scan with your banking app'),
    (Key: 'invoicenumber'; De: 'Rechnungsnummer'; En: 'invoice number'),
    (Key: 'otheraccount'; De: 'Weiteres Konto'; En: 'Further account'),
    (Key: 'ibaninvalid'; De: 'IBAN ungültig (Prüfziffer oder Aufbau falsch), bitte beim Rechnungssteller nachfragen'; En: 'IBAN invalid (check digits or structure wrong), please ask the seller'),
    (Key: 'nocode-currency'; De: 'Kein QR-Code: Der GiroCode gilt nur für Euro'; En: 'No QR code: the GiroCode is for euro only'),
    (Key: 'nocode-account'; De: 'Kein QR-Code: Die Rechnung nennt kein Konto'; En: 'No QR code: the invoice names no account'),
    (Key: 'nocode-noiban'; De: 'Kein QR-Code: Das Konto ist keine IBAN'; En: 'No QR code: the account is no IBAN'),
    (Key: 'accountno'; De: 'Konto'; En: 'Account'),
    (Key: 'nocode-amount'; De: 'Kein QR-Code: Der Zahlbetrag fehlt oder ist unbrauchbar'; En: 'No QR code: the amount due is missing or unusable'),
    (Key: 'nocode-name'; De: 'Kein QR-Code: Der Empfänger fehlt'; En: 'No QR code: the payee is missing'),
    (Key: 'nocode-long'; De: 'Kein QR-Code: Die Angaben sind zu lang'; En: 'No QR code: the data is too long'),
    (Key: 'directdebit'; De: 'Wird per Lastschrift eingezogen'; En: 'Will be collected by direct debit'),
    (Key: 'nothingtopay'; De: 'Nichts zu zahlen'; En: 'Nothing to pay'),
    (Key: 'credit'; De: 'Gutschrift zugunsten des Käufers, nichts zu überweisen'; En: 'Credit in favour of the buyer, nothing to transfer')
  );

  CSS =
    'body{font:14px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,Arial,sans-serif;color:#222;' +
    'margin:0;background:#f4f4f2}' +
    'main{max-width:960px;margin:24px auto;background:#fff;padding:32px 40px;' +
    'box-shadow:0 1px 4px rgba(0,0,0,.12)}' +
    'h1{font-size:24px;margin:0 0 4px}h2{font-size:15px;margin:28px 0 8px;' +
    'border-bottom:1px solid #ddd;padding-bottom:4px}' +
    '.sub{color:#666}.small{font-size:12px;color:#555}' +
    '.parties{display:flex;flex-wrap:wrap;gap:16px;margin-top:20px}' +
    '.party{flex:1 1 260px;border:1px solid #e3e3e3;border-radius:4px;padding:10px 14px}' +
    '.party h3{margin:0 0 6px;font-size:12px;text-transform:uppercase;color:#777;letter-spacing:.04em}' +
    '.party .name{font-weight:600}' +
    'table{border-collapse:collapse;width:100%}' +
    'th,td{text-align:left;padding:5px 8px;vertical-align:top;border-bottom:1px solid #eee}' +
    'th{font-size:12px;color:#666;font-weight:600;border-bottom:1px solid #ccc}' +
    '.num{text-align:right;white-space:nowrap}' +
    'table.meta td:first-child{color:#666;width:38%}' +
    'table.totals{width:auto;margin-left:auto;min-width:340px}' +
    'table.totals tr.strong td{font-weight:700;border-top:2px solid #333}' +
    'tr.sub td:nth-child(2){padding-left:28px}' +
    '.status{display:inline-block;padding:3px 10px;border-radius:12px;font-size:12px;margin-top:8px}' +
    '.ok{background:#e3f4e6;color:#1d6b2c}.bad{background:#fbe4e4;color:#9b1c1c}' +
    '.warn{background:#fff3d6;color:#7a5600}' +
    'pre{white-space:pre-wrap;font:inherit;margin:0}' +
    'details{margin-top:16px}summary{cursor:pointer;color:#555}' +
    'footer{margin-top:32px;font-size:11px;color:#999}footer a{color:#999}' +
    '.pay{display:flex;flex-wrap:wrap;gap:16px 24px;align-items:flex-start;border:1px solid #d5ddd5;' +
    'border-radius:4px;padding:12px 16px;background:#fafcfa;break-inside:avoid}' +
    '.pay table{flex:1 1 320px;width:auto}.pay td{border-bottom:none;padding:3px 8px}' +
    '.pay td:first-child{color:#666;white-space:nowrap;padding-right:16px}' +
    '.sel{-webkit-user-select:all;user-select:all;font-weight:600}' +
    '.iban span+span{margin-left:.35em}' +
    '.qr{margin:0;width:150px;text-align:center;font-size:12px;color:#555}' +
    '.qr svg{display:block;width:150px;height:150px}' +
    '.paynote{font-size:15px;margin:8px 0}' +
    '@media print{body{background:#fff}main{box-shadow:none;margin:0;max-width:none}details{display:none}' +
    '.pay{background:none}}';

type
  THtml = record
    SB: TStringBuilder;
    En: Boolean;
    procedure W(const s: string);
    function L(const Key: string): string;
    function Fmt(const d: TAbDecimal; MinDec: Integer): string;
    function Amount(const d: TAbDecimal): string;
    function Date(const s: string): string;
    function Plain(const d: TAbDecimal): string;   // 2 decimals, no thousands separator
    procedure Row(const Lbl, Value: string);   // escaped value
    procedure RowHtml(const Lbl, Html: string);
  end;

function Esc(const s: string): string;
var
  i: Integer;
begin
  result := '';

  for i := 1 to Length(s) do begin
    case s[i] of
      '&': result := result + '&amp;';
      '<': result := result + '&lt;';
      '>': result := result + '&gt;';
      '"': result := result + '&quot;';
      '''': result := result + '&#39;';
    else
      if (s[i] < ' ') and (s[i] <> #10) and (s[i] <> #9) then begin
        result := result + ' ';
      end else begin
        result := result + s[i];
      end;
    end;
  end;
end;

{ multi-line text: escaped, line breaks kept }
function EscLines(const s: string): string;
begin
  result := StringReplace(Esc(s), #10, '<br>', [rfReplaceAll]);
end;

procedure THtml.W(const s: string);
begin
  SB.Append(s);
end;

function THtml.L(const Key: string): string;
var
  i: Integer;
begin
  for i := 0 to High(Labels) do begin
    if Labels[i].Key = Key then begin
      if En then begin
        exit(Labels[i].En);
      end else begin
        exit(Labels[i].De);
      end;
    end;
  end;

  result := Key;
end;

{ 1234.5 -> '1.234,50' (de) / '1,234.50' (en); at least MinDec decimals }
function THtml.Fmt(const d: TAbDecimal; MinDec: Integer): string;
var
  n: TAbDecimal;
  s, intPart, frac, sep, dec: string;
  neg: Boolean;
  i, k: Integer;
begin
  if not d.Present then exit('');
  if not d.Valid then exit(d.Text);
  n := d.Normalized;
  s := n.ToString;
  neg := (s <> '') and (s[1] = '-');
  if neg then begin
    Delete(s, 1, 1);
  end;

  i := Pos('.', s);
  if i > 0 then begin
    intPart := Copy(s, 1, i - 1);
    frac := Copy(s, i + 1, MaxInt);
  end else begin
    intPart := s;
    frac := '';
  end;

  while Length(frac) < MinDec do begin
    frac := frac + '0';
  end;

  if En then begin
    sep := ',';
    dec := '.';
  end else begin
    sep := '.';
    dec := ',';
  end;

  s := '';
  k := 0;

  for i := Length(intPart) downto 1 do begin
    if (k > 0) and (k mod 3 = 0) then s := sep + s;
    s := intPart[i] + s;
    Inc(k);
  end;

  if frac <> '' then s := s + dec + frac;
  if neg then s := '-' + s;
  result := s;
end;

function THtml.Amount(const d: TAbDecimal): string;
begin
  result := Fmt(d, 2);
end;

function THtml.Plain(const d: TAbDecimal): string;
var
  r: TAbDecimal;
begin
  if not d.Present then exit('');
  if not d.Valid then exit(d.Text);
  r := d.Rounded(2);

  while r.Scale < 2 do begin
    r.Value := r.Value * 10;
    Inc(r.Scale);
  end;

  result := r.ToString;
  if not En then result := StringReplace(result, '.', ',', []);
end;

function THtml.Date(const s: string): string;
begin
  if not En and (Length(s) = 10) and (s[5] = '-') and (s[8] = '-') then begin
    result := Copy(s, 9, 2) + '.' + Copy(s, 6, 2) + '.' + Copy(s, 1, 4);
  end else begin
    result := s;
  end;
end;

procedure THtml.Row(const Lbl, Value: string);
begin
  if Value <> '' then begin
    W('<tr><td>' + Esc(Lbl) + '</td><td>' + EscLines(Value) + '</td></tr>');
  end;
end;

procedure THtml.RowHtml(const Lbl, Html: string);
begin
  if Html <> '' then begin
    W('<tr><td>' + Esc(Lbl) + '</td><td>' + Html + '</td></tr>');
  end;
end;

{ ---- code names ---- }

function TypeName(const Code: string; En: Boolean): string;
begin
  if Code = '381' then result := 'Gutschrift / Rechnungskorrektur|Credit note'
  else if Code = '384' then result := 'Korrigierte Rechnung|Corrected invoice'
  else if Code = '389' then result := 'Gutschrift|Self-billed invoice'
  else if Code = '326' then result := 'Teilrechnung|Partial invoice'
  else if Code = '386' then result := 'Vorauszahlungsrechnung|Prepayment invoice'
  else if Code = '875' then result := 'Teilrechnung Bauleistung|Partial construction invoice'
  else if Code = '876' then result := 'Teilschlussrechnung Bauleistung|Partial final construction invoice'
  else if Code = '877' then result := 'Schlussrechnung Bauleistung|Final construction invoice'
  else if Code = '751' then result := 'Rechnungsinformation|Invoice information'
  else result := 'Rechnung|Invoice';
  if En then begin
    result := Copy(result, Pos('|', result) + 1, MaxInt);
  end else begin
    result := Copy(result, 1, Pos('|', result) - 1);
  end;
end;

function Pick(const s: string; En: Boolean): string;
begin
  if En then begin
    result := Copy(s, Pos('|', s) + 1, MaxInt);
  end else begin
    result := Copy(s, 1, Pos('|', s) - 1);
  end;
end;

function UnitName(const Code: string; En: Boolean): string;
begin
  if (Code = 'C62') or (Code = 'H87') or (Code = 'XPP') or (Code = 'EA') then result := Pick('Stk.|pcs', En)
  else if Code = 'HUR' then result := Pick('Std.|h', En)
  else if Code = 'MIN' then result := 'min'
  else if Code = 'DAY' then result := Pick('Tag(e)|day(s)', En)
  else if Code = 'WEE' then result := Pick('Woche(n)|week(s)', En)
  else if Code = 'MON' then result := Pick('Monat(e)|month(s)', En)
  else if Code = 'ANN' then result := Pick('Jahr(e)|year(s)', En)
  else if Code = 'KGM' then result := 'kg'
  else if Code = 'GRM' then result := 'g'
  else if Code = 'TNE' then result := 't'
  else if Code = 'MTR' then result := 'm'
  else if Code = 'KMT' then result := 'km'
  else if Code = 'MTK' then result := 'm²'
  else if Code = 'MTQ' then result := 'm³'
  else if Code = 'LTR' then result := 'l'
  else if Code = 'KWH' then result := 'kWh'
  else if Code = 'LS' then result := Pick('pauschal|lump sum', En)
  else if Code = 'SET' then result := Pick('Satz|set', En)
  else if Code = 'P1' then result := '%'
  else result := Code;
end;

function MeansName(const Code: string; En: Boolean): string;
begin
  if Code = '10' then result := Pick('Bar|Cash', En)
  else if Code = '20' then result := Pick('Scheck|Cheque', En)
  else if Code = '30' then result := Pick('Überweisung|Credit transfer', En)
  else if Code = '42' then result := Pick('Zahlung auf Bankkonto|Payment to bank account', En)
  else if Code = '48' then result := Pick('Karte|Bank card', En)
  else if Code = '49' then result := Pick('Lastschrift|Direct debit', En)
  else if Code = '54' then result := Pick('Kreditkarte|Credit card', En)
  else if Code = '55' then result := Pick('Debitkarte|Debit card', En)
  else if Code = '57' then result := Pick('Dauerauftrag|Standing agreement', En)
  else if Code = '58' then result := Pick('SEPA-Überweisung|SEPA credit transfer', En)
  else if Code = '59' then result := Pick('SEPA-Lastschrift|SEPA direct debit', En)
  else if Code = '97' then result := Pick('Verrechnung|Clearing between partners', En)
  else result := '';
end;

function CategoryName(const Code: string; En: Boolean): string;
begin
  if Code = 'S' then result := Pick('Regelsteuersatz|Standard rate', En)
  else if Code = 'Z' then result := Pick('Nullsatz|Zero rated', En)
  else if Code = 'E' then result := Pick('Steuerbefreit|Exempt', En)
  else if Code = 'AE' then result := Pick('Steuerschuldnerschaft des Leistungsempfängers|Reverse charge', En)
  else if Code = 'K' then result := Pick('Innergemeinschaftliche Lieferung|Intra-community supply', En)
  else if Code = 'G' then result := Pick('Ausfuhr|Export outside the EU', En)
  else if Code = 'O' then result := Pick('Nicht steuerbar|Not subject to VAT', En)
  else if Code = 'L' then result := 'IGIC'
  else if Code = 'M' then result := 'IPSI'
  else result := '';
end;

function WithCode(const Name, Code: string): string;
begin
  if Name = '' then begin
    result := Code;
  end else begin
    result := Name + ' (' + Code + ')';
  end;
end;

function SafeUrl(const u: string): Boolean;
begin
  result := (Pos('http://', LowerCase(u)) = 1) or (Pos('https://', LowerCase(u)) = 1);
end;

const
  SafeMime: array[0..6] of string = ('application/pdf', 'application/vnd.oasis.opendocument.spreadsheet',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', 'application/xml',
    'image/jpeg', 'image/png', 'text/csv');

{ ---- sections ---- }

procedure Party(var h: THtml; const Title: string; const p: TEInvoiceParty);
var
  i: Integer;
  a: TEInvoiceAddress;
  s: string;
begin
  h.W('<div class="party"><h3>' + Esc(Title) + '</h3>');

  if p.Name <> '' then begin
    h.W('<div class="name">' + Esc(p.Name) + '</div>');
  end;

  if (p.TradingName <> '') and (p.TradingName <> p.Name) then begin
    h.W('<div>' + Esc(p.TradingName) + '</div>');
  end;

  a := p.Address;
  if a.Line1 <> '' then h.W('<div>' + Esc(a.Line1) + '</div>');
  if a.Line2 <> '' then h.W('<div>' + Esc(a.Line2) + '</div>');
  if a.Line3 <> '' then h.W('<div>' + Esc(a.Line3) + '</div>');
  s := Trim(a.PostCode + ' ' + a.City);
  if s <> '' then h.W('<div>' + Esc(s) + '</div>');
  s := a.Subdivision;

  if a.Country <> '' then begin
    if s <> '' then s := s + ', ';
    s := s + a.Country;
  end;

  if s <> '' then h.W('<div>' + Esc(s) + '</div>');
  h.W('<div class="small" style="margin-top:6px">');
  if p.VATID <> '' then h.W(Esc(h.L('vatid')) + ': ' + Esc(p.VATID) + '<br>');
  if p.TaxNumber <> '' then h.W(Esc(h.L('taxno')) + ': ' + Esc(p.TaxNumber) + '<br>');

  if p.LegalID.Value <> '' then begin
    h.W(Esc(h.L('legalid')) + ': ' + Esc(p.LegalID.Value));
    if p.LegalID.Scheme <> '' then h.W(' (' + Esc(p.LegalID.Scheme) + ')');
    h.W('<br>');
  end;

  for i := 0 to High(p.IDs) do begin
    h.W(Esc(h.L('id')) + ': ' + Esc(p.IDs[i].Value));
    if p.IDs[i].Scheme <> '' then h.W(' (' + Esc(p.IDs[i].Scheme) + ')');
    h.W('<br>');
  end;

  if p.ElectronicAddress.Value <> '' then begin
    h.W(Esc(h.L('eaddress')) + ': ' + Esc(p.ElectronicAddress.Value) + '<br>');
  end;

  if p.Contact.Name <> '' then h.W(Esc(h.L('contact')) + ': ' + Esc(p.Contact.Name) + '<br>');
  if p.Contact.Phone <> '' then h.W(Esc(h.L('phone')) + ': ' + Esc(p.Contact.Phone) + '<br>');
  if p.Contact.Email <> '' then h.W(Esc(h.L('email')) + ': ' + Esc(p.Contact.Email) + '<br>');
  if p.LegalInfo <> '' then h.W(EscLines(p.LegalInfo) + '<br>');
  h.W('</div></div>');
end;

function HasPartyData(const p: TEInvoiceParty): Boolean;
begin
  result := (p.Name <> '') or (p.VATID <> '') or (p.Address.City <> '') or (Length(p.IDs) > 0) or
    (p.LegalID.Value <> '');
end;

procedure CheckSection(var h: THtml; const Rep: TAbCheckReport);
var
  i: Integer;
  cls, sev: string;
begin
  if Rep.Errors > 0 then begin
    h.W('<span class="status bad">' + Esc(h.L('check')) + ': ' + IntToStr(Rep.Errors) + ' ' +
      Esc(h.L('errors')) + '</span> ');
  end else begin
    h.W('<span class="status ok">' + Esc(h.L('check')) + ': ' + Esc(h.L('checkok')) + '</span> ');
  end;

  if Rep.Warnings > 0 then begin
    h.W('<span class="status warn">' + IntToStr(Rep.Warnings) + ' ' + Esc(h.L('warnings')) + '</span>');
  end;

  if (Length(Rep.Messages) = 0) and (Length(Rep.NotChecked) = 0) then exit;
  h.W('<details' + IfThen(Rep.Errors > 0, ' open', '') + '><summary>' + Esc(h.L('check')) + '</summary><table>');

  for i := 0 to High(Rep.Messages) do begin
    case Rep.Messages[i].Severity of
      abError: begin cls := 'bad'; sev := 'E'; end;
      abWarning: begin cls := 'warn'; sev := 'W'; end;
    else
      cls := '';
      sev := 'I';
    end;

    h.W('<tr><td><span class="status ' + cls + '">' + sev + '</span></td><td>' + Esc(Rep.Messages[i].Code) +
      IfThen(Rep.Messages[i].Origin = aboExtra, '<br><small>' + Esc(h.L('extra')) + '</small>', '') +
      '</td><td>' + Esc(Rep.Messages[i].Text) + '</td></tr>');
  end;

  for i := 0 to High(Rep.NotChecked) do begin
    h.W('<tr><td></td><td>' + Esc(h.L('notchecked')) + '</td><td>' + Esc(Rep.NotChecked[i]) + '</td></tr>');
  end;

  h.W('</table></details>');
end;

procedure Lines(var h: THtml; const Inv: TEInvoice);
var
  i, j: Integer;
  l: TEInvoiceLine;
  extra, price, s, sep: string;
  ac: TEInvoiceAllowanceCharge;
begin
  sep := ' · ';  // a variable: under FPC, Length of a literal would count UTF-16 units
  h.W('<h2>' + Esc(h.L('lines')) + '</h2><table><tr><th>' + Esc(h.L('pos')) + '</th><th>' + Esc(h.L('item')) +
    '</th><th class="num">' + Esc(h.L('qty')) + '</th><th class="num">' + Esc(h.L('price')) +
    '</th><th class="num">' + Esc(h.L('vat')) + '</th><th class="num">' + Esc(h.L('net')) + '</th></tr>');

  for i := 0 to High(Inv.Lines) do begin
    l := Inv.Lines[i];
    extra := '';
    if l.ItemDescription <> '' then extra := extra + EscLines(l.ItemDescription) + '<br>';
    s := '';
    if l.SellerItemID <> '' then s := s + Esc(h.L('sellerid')) + ' ' + Esc(l.SellerItemID) + ' · ';
    if l.BuyerItemID <> '' then s := s + Esc(h.L('buyeritem')) + ' ' + Esc(l.BuyerItemID) + ' · ';

    if l.StandardItemID.Value <> '' then begin
      s := s + Esc(l.StandardItemID.Value) + IfThen(l.StandardItemID.Scheme <> '', ' (' + Esc(l.StandardItemID.Scheme) + ')', '') + ' · ';
    end;

    for j := 0 to High(l.Classifications) do begin
      s := s + Esc(l.Classifications[j].Value) + IfThen(l.Classifications[j].Scheme <> '', ' (' + Esc(l.Classifications[j].Scheme) + ')', '') + ' · ';
    end;

    if l.OriginCountry <> '' then s := s + Esc(h.L('origin')) + ' ' + Esc(l.OriginCountry) + ' · ';
    if l.OrderLineRef <> '' then s := s + Esc(h.L('orderline')) + ' ' + Esc(l.OrderLineRef) + ' · ';

    if (l.PeriodStart <> '') or (l.PeriodEnd <> '') then begin
      s := s + Esc(h.Date(l.PeriodStart)) + ' – ' + Esc(h.Date(l.PeriodEnd)) + ' · ';
    end;

    if l.ObjectID.Value <> '' then s := s + Esc(h.L('object')) + ' ' + Esc(l.ObjectID.Value) + ' · ';
    if l.AccountingRef <> '' then s := s + Esc(h.L('accounting')) + ' ' + Esc(l.AccountingRef) + ' · ';
    // drop the last separator (3 chars under Delphi, 4 bytes under FPC)
    if s <> '' then extra := extra + Copy(s, 1, Length(s) - Length(sep)) + '<br>';

    for j := 0 to High(l.Attributes) do begin
      extra := extra + Esc(l.Attributes[j].Name) + ': ' + Esc(l.Attributes[j].Value) + '<br>';
    end;

    if l.Note <> '' then extra := extra + '<i>' + EscLines(l.Note) + '</i><br>';

    for j := 0 to High(l.AllowancesCharges) do begin
      ac := l.AllowancesCharges[j];
      if ac.IsCharge then s := h.L('charge') else s := h.L('allowance');
      s := Esc(s);
      if ac.Reason <> '' then s := s + ' ' + Esc(ac.Reason);
      if ac.Percent.Present then s := s + ' ' + Esc(h.Fmt(ac.Percent, 0)) + ' %';
      s := s + ': ' + IfThen(ac.IsCharge, '+', '−') + Esc(h.Amount(ac.Amount));
      extra := extra + s + '<br>';
    end;

    price := Esc(h.Amount(l.NetPrice));

    if l.BaseQuantity.Present and not l.BaseQuantity.Equals(TAbDecimal.FromInt(1)) then begin
      price := price + '<br><span class="small">' + Esc(h.L('per')) + ' ' + Esc(h.Fmt(l.BaseQuantity, 0)) +
        ' ' + Esc(UnitName(l.BaseQuantityUnit, h.En)) + '</span>';
    end;

    if l.GrossPrice.Present and not l.GrossPrice.Equals(l.NetPrice) then begin
      price := price + '<br><span class="small">' + Esc(h.L('gross')) + ' ' + Esc(h.Amount(l.GrossPrice)) + '</span>';
    end;

    h.W('<tr' + IfThen(l.ParentID <> '', ' class="sub"', '') + '><td>' + Esc(l.ID) + '</td><td><b>' +
      Esc(l.ItemName) + '</b>');

    if extra <> '' then begin
      h.W('<div class="small">' + extra + '</div>');
    end;

    h.W('</td><td class="num">' + Esc(h.Fmt(l.Quantity, 0)) + ' ' + Esc(UnitName(l.UnitCode, h.En)) +
      '</td><td class="num">' + price + '</td><td class="num">' + Esc(l.TaxCategory));

    if l.TaxRate.Present then begin
      h.W(' ' + Esc(h.Fmt(l.TaxRate, 0)) + ' %');
    end;

    h.W('</td><td class="num">' + Esc(h.Amount(l.NetAmount)) + '</td></tr>');
  end;

  h.W('</table>');
end;

procedure Totals(var h: THtml; const Inv: TEInvoice);
var
  i: Integer;
  t: TEInvoiceTotals;
  ac: TEInvoiceAllowanceCharge;
  s: string;

  procedure TR(const Key: string; const d: TAbDecimal; Strong: Boolean = false);
  begin
    if d.Present then begin
      h.W('<tr' + IfThen(Strong, ' class="strong"', '') + '><td>' + Esc(h.L(Key)) + '</td><td class="num">' +
        Esc(h.Amount(d)) + ' ' + Esc(Inv.Currency) + '</td></tr>');
    end;
  end;

begin
  if Length(Inv.AllowancesCharges) > 0 then begin
    h.W('<h2>' + Esc(h.L('allowcharge')) + '</h2><table>');

    for i := 0 to High(Inv.AllowancesCharges) do begin
      ac := Inv.AllowancesCharges[i];
      if ac.IsCharge then s := h.L('charge') else s := h.L('allowance');
      if ac.Reason <> '' then s := s + ': ' + ac.Reason;
      if ac.ReasonCode <> '' then s := s + ' (' + ac.ReasonCode + ')';
      h.W('<tr><td>' + Esc(s));

      if ac.Percent.Present then begin
        h.W('<br><span class="small">' + Esc(h.Fmt(ac.Percent, 0)) + ' % ' + Esc(h.L('of')) + ' ' +
          Esc(h.Amount(ac.BaseAmount)) + '</span>');
      end;

      h.W('</td><td class="num">' + Esc(ac.TaxCategory) + IfThen(ac.TaxRate.Present, ' ' + Esc(h.Fmt(ac.TaxRate, 0)) + ' %', '') +
        '</td><td class="num">' + IfThen(ac.IsCharge, '+', '−') + Esc(h.Amount(ac.Amount)) + '</td></tr>');
    end;

    h.W('</table>');
  end;

  if Length(Inv.Taxes) > 0 then begin
    h.W('<h2>' + Esc(h.L('vatbreakdown')) + '</h2><table><tr><th>' + Esc(h.L('category')) + '</th><th class="num">' +
      Esc(h.L('rate')) + '</th><th class="num">' + Esc(h.L('taxable')) + '</th><th class="num">' +
      Esc(h.L('taxamount')) + '</th></tr>');

    for i := 0 to High(Inv.Taxes) do begin
      h.W('<tr><td>' + Esc(WithCode(CategoryName(Inv.Taxes[i].Category, h.En), Inv.Taxes[i].Category)));
      s := Inv.Taxes[i].ExemptionReason;

      if Inv.Taxes[i].ExemptionReasonCode <> '' then begin
        s := Trim(s + ' (' + Inv.Taxes[i].ExemptionReasonCode + ')');
      end;

      if s <> '' then begin
        h.W('<br><span class="small">' + Esc(h.L('exemption')) + ': ' + Esc(s) + '</span>');
      end;

      h.W('</td><td class="num">' + IfThen(Inv.Taxes[i].Rate.Present, Esc(h.Fmt(Inv.Taxes[i].Rate, 0)) + ' %', '') +
        '</td><td class="num">' + Esc(h.Amount(Inv.Taxes[i].TaxableAmount)) + '</td><td class="num">' +
        Esc(h.Amount(Inv.Taxes[i].TaxAmount)) + '</td></tr>');
    end;

    h.W('</table>');
  end;

  t := Inv.Totals;
  h.W('<table class="totals" style="margin-top:16px">');
  TR('linetotal', t.LineTotal);
  TR('allowancetotal', t.AllowanceTotal);
  TR('chargetotal', t.ChargeTotal);
  TR('taxexclusive', t.TaxExclusive);
  TR('taxtotal', t.TaxTotal);

  if t.TaxTotalTaxCurrency.Present then begin
    h.W('<tr><td>' + Esc(h.L('taxtotalcur')) + '</td><td class="num">' + Esc(h.Amount(t.TaxTotalTaxCurrency)) +
      ' ' + Esc(Inv.TaxCurrency) + '</td></tr>');
  end;

  TR('taxinclusive', t.TaxInclusive);
  TR('prepaid', t.Prepaid);
  TR('rounding', t.Rounding);
  TR('duepayable', t.DuePayable, true);
  h.W('</table>');
end;

{ an IBAN in groups of four: separate spans, so that copying gives no spaces }
function IbanHtml(const IBAN: string): string;
var
  i: Integer;
begin
  result := '';
  i := 1;

  while i <= Length(IBAN) do begin
    result := result + '<span>' + Esc(Copy(IBAN, i, 4)) + '</span>';
    i := i + 4;
  end;
end;

{ a GiroCode with a caption (already HTML) }
function QrFigure(const Code, Caption: string): string;
var
  qr: TQrCode;
begin
  result := '';
  if not QrEncode(Utf8Bytes(Code), qr) then exit;
  result := '<figure class="qr">' + QrSvg(qr, 'GiroCode') + '<figcaption>' + Caption + '</figcaption></figure>';
end;

{ like a transfer form: recipient, IBAN, BIC, amount, remittance, due date,
  Skonto, and the codes }
procedure TransferBox(var h: THtml; const Inv: TEInvoice; const p: TPayInfo);
var
  i: Integer;
  s, codes, cur: string;
  d: TPayDiscount;
begin
  cur := ' ' + Esc(p.Currency);
  h.W('<div class="pay"><table>');
  if p.Name <> '' then h.RowHtml(h.L('recipient'), '<span class="sel">' + Esc(p.Name) + '</span>');

  if (p.IBAN <> '') and not p.IsIBAN then begin
    h.RowHtml(h.L('accountno'), '<span class="sel">' + Esc(p.IBAN) + '</span>');
  end else if p.IBAN <> '' then begin
    s := '<span class="sel iban">' + IbanHtml(p.IBAN) + '</span>';
    if not p.IBANValid then s := s + '<br><span class="status bad">' + Esc(h.L('ibaninvalid')) + '</span>';
    h.RowHtml('IBAN', s);
  end;

  if p.BIC <> '' then h.RowHtml(h.L('bic'), '<span class="sel">' + Esc(p.BIC) + '</span>');
  if p.Amount.Present then h.RowHtml(h.L('amount'), '<span class="sel">' + Esc(h.Plain(p.Amount)) + '</span>' + cur);

  if p.Remittance <> '' then begin
    s := '<span class="sel">' + EscLines(p.Remittance) + '</span>';

    if Trim(Inv.Payment.RemittanceInfo) = '' then begin
      s := s + ' <span class="small">(' + Esc(h.L('invoicenumber')) + ')</span>';
    end;

    h.RowHtml(h.L('remittance'), s);
  end;

  h.Row(h.L('duedate'), h.Date(p.DueDate));

  for i := 0 to High(p.Discounts) do begin
    d := p.Discounts[i];
    s := Esc(h.Fmt(d.Percent, 0)) + ' %';
    if d.Deadline <> '' then s := s + ' ' + Esc(h.L('until')) + ' ' + Esc(h.Date(d.Deadline));
    s := s + ' (' + IntToStr(d.Days) + ' ' + Esc(h.L('days')) + '): <span class="sel">' + Esc(h.Plain(d.Amount)) +
      '</span>' + cur;
    h.RowHtml(h.L('skonto'), s);
  end;

  h.W('</table>');
  codes := '';

  if p.Code <> '' then begin
    codes := QrFigure(p.Code, Esc(h.L('duepayable')) + ' ' + Esc(h.Amount(p.Amount)) + cur);

    for i := 0 to High(p.Discounts) do begin
      d := p.Discounts[i];
      if d.Code = '' then continue;
      s := Esc(h.L('skonto')) + ' ' + Esc(h.Fmt(d.Percent, 0)) + ' %';
      if d.Deadline <> '' then s := s + ' ' + Esc(h.L('until')) + ' ' + Esc(h.Date(d.Deadline));
      codes := codes + QrFigure(d.Code, s + ':<br>' + Esc(h.Amount(d.Amount)) + cur);
    end;
  end;

  h.W(codes + '</div>');

  if p.Code <> '' then begin
    h.W('<p class="small">' + Esc(h.L('scan')) + '</p>');
  end else begin
    case p.NoCode of
      pncCurrency: s := 'nocode-currency';
      pncNoAccount: s := 'nocode-account';
      pncNoIBAN: s := 'nocode-noiban';
      pncAmount: s := 'nocode-amount';
      pncName: s := 'nocode-name';
      pncTooLong: s := 'nocode-long';
    else
      s := '';   // invalid IBAN: said at the IBAN
    end;

    if s <> '' then h.W('<p class="small">' + Esc(h.L(s)) + '</p>');
  end;
end;

procedure Payment(var h: THtml; const Inv: TEInvoice);
var
  p: TPayInfo;
  pm: TEInvoicePayment;
  i: Integer;
  first, transfer: Boolean;
begin
  p := PaymentInfo(Inv);
  pm := Inv.Payment;
  if (p.Kind = pkNone) and (pm.MeansCode = '') and (Length(pm.Accounts) = 0) and (Inv.PaymentTerms = '') and
    (Inv.DueDate = '') and (pm.MandateID = '') then exit;
  transfer := p.Kind = pkTransfer;
  h.W('<h2>' + Esc(h.L('payment')) + '</h2>');

  case p.Kind of
    pkTransfer: TransferBox(h, Inv, p);
    pkDirectDebit: h.W('<p class="paynote">' + Esc(h.L('directdebit')) + ': <b>' + Esc(h.Amount(p.Amount)) + ' ' +
      Esc(p.Currency) + '</b></p>');
    pkNothingToPay: h.W('<p class="paynote"><span class="status ok">' + Esc(h.L('nothingtopay')) + '</span></p>');
    pkCredit: h.W('<p class="paynote">' + Esc(h.L('credit')) + ': <b>' + Esc(h.Amount(p.Amount)) + ' ' +
      Esc(p.Currency) + '</b></p>');
  end;

  // everything else said about payment (what the box shows is left out)
  h.W('<table class="meta">');

  if pm.MeansCode <> '' then begin
    h.Row(h.L('means'), WithCode(IfThen(pm.MeansText <> '', pm.MeansText, MeansName(pm.MeansCode, h.En)), pm.MeansCode));
  end;

  if not transfer then h.Row(h.L('duedate'), h.Date(Inv.DueDate));
  first := true;

  for i := 0 to High(pm.Accounts) do begin
    // the account in the box: the first one with an IBAN
    if transfer and first and (Trim(pm.Accounts[i].IBAN) <> '') then begin
      first := false;
      continue;
    end;

    h.Row(IfThen(transfer, h.L('otheraccount'), h.L('account')), pm.Accounts[i].IBAN);
    h.Row(h.L('bic'), pm.Accounts[i].BIC);
    h.Row(h.L('accountname'), pm.Accounts[i].Name);
  end;

  if not transfer then h.Row(h.L('remittance'), pm.RemittanceInfo);
  h.Row(h.L('card'), Trim(pm.CardNumber + ' ' + pm.CardHolder));
  h.Row(h.L('mandate'), pm.MandateID);
  h.Row(h.L('creditor'), pm.CreditorID);
  h.Row(h.L('debited'), pm.DebitedAccount);

  if Trim(Inv.PaymentTerms) <> '' then begin
    h.RowHtml(h.L('terms'), '<pre>' + Esc(Trim(Inv.PaymentTerms)) + '</pre>');
  end;

  h.W('</table>');
end;

procedure Documents(var h: THtml; const Inv: TEInvoice);
var
  i: Integer;
  d: TEInvoiceDocument;
  mime, name: string;
  okMime: Boolean;
  j: Integer;
begin
  if Length(Inv.Documents) = 0 then exit;
  h.W('<h2>' + Esc(h.L('documents')) + '</h2><table>');

  for i := 0 to High(Inv.Documents) do begin
    d := Inv.Documents[i];
    h.W('<tr><td>' + Esc(d.ID) + '</td><td>' + EscLines(d.Description));

    if Length(d.Content) > 0 then begin
      mime := LowerCase(d.MimeType);
      okMime := false;

      for j := 0 to High(SafeMime) do begin
        if SafeMime[j] = mime then okMime := true;
      end;

      if not okMime then mime := 'application/octet-stream';
      name := d.FileName;
      if name = '' then name := 'attachment-' + IntToStr(i + 1);
      h.W('<br><a download="' + Esc(name) + '" href="data:' + mime + ';base64,' + EncodeBase64(d.Content) + '">' +
        Esc(name) + '</a> <span class="small">(' + Esc(d.MimeType) + ', ' + IntToStr(Length(d.Content)) +
        ' Bytes, ' + Esc(h.L('download')) + ')</span>');
    end;

    if d.URI <> '' then begin
      if SafeUrl(d.URI) then begin
        h.W('<br><a href="' + Esc(d.URI) + '" rel="noopener noreferrer">' + Esc(d.URI) + '</a>');
      end else begin
        h.W('<br>' + Esc(d.URI));
      end;
    end;

    h.W('</td></tr>');
  end;

  h.W('</table>');
end;

procedure Technical(var h: THtml; const Inv: TEInvoice);
var
  i: Integer;
  s: string;
begin
  h.W('<details><summary>' + Esc(h.L('technical')) + '</summary><table class="meta">');
  h.Row(h.L('syntax'), TAbdecker.SyntaxName(Inv.Info.Syntax));
  s := TAbdecker.ProfileName(Inv.Info.Profile);
  if Inv.Info.XRechnungVersion <> '' then s := s + ' ' + Inv.Info.XRechnungVersion;
  h.Row(h.L('profile'), s);
  h.Row(h.L('spec'), Inv.Specification);
  h.Row(h.L('process'), Inv.BusinessProcess);

  if Inv.Info.Container = eicontPDF then begin
    s := 'PDF ' + Inv.Info.PDFVersion;

    if Inv.Info.PDFAPart <> '' then begin
      s := s + ', PDF/A-' + Inv.Info.PDFAPart + LowerCase(Inv.Info.PDFAConformance);
    end;

    h.Row(h.L('container'), s);
    s := '';

    for i := 0 to High(Inv.Info.Attachments) do begin
      s := s + Inv.Info.Attachments[i].Name + #10;
    end;

    h.Row(h.L('pdfattach'), Trim(s));
  end;

  h.W('</table></details>');

  if Length(Inv.Unmapped) > 0 then begin
    h.W('<details><summary>' + Esc(h.L('unmapped')) + ' (' + IntToStr(Length(Inv.Unmapped)) +
      ')</summary><table>');

    for i := 0 to High(Inv.Unmapped) do begin
      h.W('<tr><td class="small">' + Esc(Inv.Unmapped[i]) + '</td></tr>');
    end;

    h.W('</table></details>');
  end;
end;

procedure Footer(var h: THtml);
begin
  h.W('<footer>' + Esc(h.L('created')) + ' abdecker ' + Esc(AbdeckerVersion) + ' ' + Esc(h.L('by')) + ' ' +
    Esc(AbdeckerAuthor) + ' &middot; <a href="' + AbdeckerRepo + '">' + Esc(Copy(AbdeckerRepo, 9, MaxInt)) +
    '</a> &middot; <a href="' + AbdeckerHome + '">' + Esc(Copy(AbdeckerHome, 9, MaxInt)) + '</a></footer>'#10);
end;

function InvoiceHtml(const Inv: TEInvoice; const Rep: TAbCheckReport; WithCheck: Boolean;
  const Lang: string; PaymentOnly: Boolean): string;
var
  h: THtml;
  i: Integer;
  s, title: string;
begin
  h.En := LowerCase(Lang) = 'en';
  h.SB := TStringBuilder.Create;

  try
    title := TypeName(Inv.TypeCode, h.En) + ' ' + Inv.Number;
    s := title;
    if PaymentOnly then s := h.L('payment') + ': ' + title;
    h.W('<!DOCTYPE html>'#10'<html lang="' + IfThen(h.En, 'en', 'de') + '"><head><meta charset="utf-8">'#10 +
      '<meta http-equiv="Content-Security-Policy" content="default-src ''none''; style-src ''unsafe-inline''; ' +
      'img-src data:">'#10'<meta name="viewport" content="width=device-width, initial-scale=1">'#10 +
      '<meta name="generator" content="abdecker ' + Esc(AbdeckerVersion) + '">'#10 +
      '<title>' + Esc(s) + '</title>'#10'<style>' + CSS + '</style></head>'#10'<body><main>'#10);

    // header
    h.W('<h1>' + Esc(title) + '</h1><div class="sub">');
    s := h.Date(Inv.IssueDate);
    if Inv.Seller.Name <> '' then s := Inv.Seller.Name + ' · ' + s;
    h.W(Esc(s) + '</div>');

    if WithCheck then begin
      CheckSection(h, Rep);
    end;

    if PaymentOnly then begin
      Payment(h, Inv);
      Footer(h);
      h.W('</main></body></html>'#10);
      exit(h.SB.ToString);
    end;

    // parties
    h.W('<div class="parties">');
    Party(h, h.L('seller'), Inv.Seller);
    Party(h, h.L('buyer'), Inv.Buyer);
    h.W('</div>');

    if HasPartyData(Inv.Payee) or HasPartyData(Inv.TaxRepresentative) then begin
      h.W('<div class="parties">');

      if HasPartyData(Inv.Payee) then begin
        Party(h, h.L('payee'), Inv.Payee);
      end;

      if HasPartyData(Inv.TaxRepresentative) then begin
        Party(h, h.L('taxrep'), Inv.TaxRepresentative);
      end;

      h.W('</div>');
    end;

    // details
    h.W('<h2>' + Esc(TypeName(Inv.TypeCode, h.En)) + '</h2><table class="meta">');
    h.Row(h.L('number'), Inv.Number);
    h.Row(h.L('issuedate'), h.Date(Inv.IssueDate));
    h.Row(h.L('deliverydate'), h.Date(Inv.Delivery.Date));

    if (Inv.PeriodStart <> '') or (Inv.PeriodEnd <> '') then begin
      h.Row(h.L('period'), h.Date(Inv.PeriodStart) + ' – ' + h.Date(Inv.PeriodEnd));
    end;

    h.Row(h.L('taxpoint'), h.Date(Inv.TaxPointDate));
    h.Row(h.L('buyerref'), Inv.BuyerReference);
    h.Row(h.L('orderref'), Inv.OrderRef);
    h.Row(h.L('salesorder'), Inv.SalesOrderRef);
    h.Row(h.L('contract'), Inv.ContractRef);
    h.Row(h.L('project'), Inv.ProjectRef);
    h.Row(h.L('despatch'), Inv.DespatchAdviceRef);
    h.Row(h.L('receiving'), Inv.ReceivingAdviceRef);
    h.Row(h.L('tender'), Inv.TenderRef);
    h.Row(h.L('object'), Inv.InvoicedObject.Value);
    h.Row(h.L('accounting'), Inv.AccountingRef);

    for i := 0 to High(Inv.PrecedingInvoices) do begin
      h.Row(h.L('preceding'), Trim(Inv.PrecedingInvoices[i].Number + IfThen(Inv.PrecedingInvoices[i].Date <> '',
        ' ' + h.L('of') + ' ' + h.Date(Inv.PrecedingInvoices[i].Date), '')));
    end;

    h.Row(h.L('currency'), Inv.Currency);
    h.Row(h.L('taxcurrency'), Inv.TaxCurrency);
    h.W('</table>');

    // delivery
    if (Inv.Delivery.PartyName <> '') or (Inv.Delivery.Address.City <> '') or (Inv.Delivery.LocationID.Value <> '') then begin
      h.W('<h2>' + Esc(h.L('deliverto')) + '</h2><table class="meta">');
      h.Row(h.L('recipient'), Inv.Delivery.PartyName);
      h.Row(h.L('location'), Inv.Delivery.LocationID.Value);
      s := Inv.Delivery.Address.Line1;
      if Inv.Delivery.Address.Line2 <> '' then s := s + #10 + Inv.Delivery.Address.Line2;
      if Inv.Delivery.Address.Line3 <> '' then s := s + #10 + Inv.Delivery.Address.Line3;
      s := Trim(s + #10 + Trim(Inv.Delivery.Address.PostCode + ' ' + Inv.Delivery.Address.City) + #10 +
        Inv.Delivery.Address.Country);
      h.Row(h.L('delivery'), s);
      h.W('</table>');
    end;

    Lines(h, Inv);
    Totals(h, Inv);
    Payment(h, Inv);

    if Length(Inv.Notes) > 0 then begin
      h.W('<h2>' + Esc(h.L('notes')) + '</h2>');

      for i := 0 to High(Inv.Notes) do begin
        h.W('<p>');

        if Inv.Notes[i].SubjectCode <> '' then begin
          h.W('<span class="small">' + Esc(Inv.Notes[i].SubjectCode) + '</span> ');
        end;

        h.W(EscLines(Inv.Notes[i].Text) + '</p>');
      end;
    end;

    Documents(h, Inv);
    Technical(h, Inv);
    Footer(h);
    h.W('</main></body></html>'#10);
    result := h.SB.ToString;
  finally
    h.SB.Free;
  end;
end;

end.
