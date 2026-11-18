{ SPDX-License-Identifier: MIT
  Copyright (c) 2026 Ingo Jache }

unit abdecker;

{ ---------------------------------------------------------------------------
  abdecker - e-invoices (XRechnung, ZUGFeRD, Factur-X) for Delphi and FPC

  Status:  work in progress

  This unit is the whole public API: types and the class TAbdecker.
  The other units are internal building blocks:
    abdecker.util   helpers (messages, UTF-8, byte search, base64, files)
    abdecker.xml    minimal XML reader
    abdecker.pdf    PDF reader and stream filters
    abdecker.zlib   zlib compression (System.ZLib or paszlib, kept in one unit)
    abdecker.read   format detection, model reader, dispatch to the syntaxes
    abdecker.cii    CII and ZUGFeRD 1.0 -> TEInvoice, TEInvoice -> CII
    abdecker.ubl    UBL -> TEInvoice
    abdecker.check  plausibility check (EN 16931, XRechnung)
    abdecker.embed  embed an invoice into a PDF, or remove it (incremental update)
    abdecker.attach add supporting documents (BG-24) to an invoice XML
    abdecker.html   invoice as an HTML page
    abdecker.payment what is to be paid, the GiroCode text
    abdecker.qr     QR code encoder (byte mode, level M), SVG
    abdecker.json   results as JSON (common format of --json and serve), JSON reader
    abdecker.format the own invoice format (JSON) <-> TEInvoice

  Design rules:
  - RTL only, no exceptions leave the public API (result code + messages)
  - no mutable global state; everything lives in records on the stack
  - the public API is a class with static class functions (no instance)
  - conservative language subset so that FPC (mode delphi) can follow
  --------------------------------------------------------------------------- }

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
{$IFDEF FPC}
  SysUtils, Classes;
{$ELSE}
  System.SysUtils, System.Classes;
{$ENDIF}

const
  AbdeckerVersion = '0.1.0-dev';
  AbdeckerAuthor = 'Ingo Jache';
  AbdeckerRepo = 'https://github.com/ijache/abdecker';
  AbdeckerHome = 'https://abdecker.jache.de';

type
  TAbResult = (
    abOK,             // success
    abNoInvoice,      // readable, but no e-invoice inside
    abUnknownFormat,  // neither PDF nor a known XML invoice format
    abFileError,      // file could not be read or written
    abBrokenPDF,      // PDF structure not readable
    abBrokenXML,      // XML not well-formed
    abEncrypted,      // encrypted PDF (not supported)
    abUnsupported,    // operation not supported for this input
    abInvalidData,    // invoice data (own JSON format) broken or incomplete
    abInternalError); // bug - please report

  TAbSeverity = (abInfo, abWarning, abError);

  { Where a message comes from:
    aboFile     - reading the file (PDF structure, XMP, numbers ...)
    aboOfficial - a rule of an official rule set (EN 16931, XRechnung, Peppol),
                  applied where that rule set applies
    aboExtra    - an additional check of abdecker that no official rule set
                  demands (own AB-* rules, or an official rule applied beyond
                  its rule set, e.g. PEPPOL-EN16931-R120 on a ZUGFeRD invoice) }
  TAbOrigin = (aboFile, aboOfficial, aboExtra);

  TAbMessage = record
    Severity: TAbSeverity;
    Code: string;   // stable identifier, e.g. 'PDF-XREF' or 'BR-CO-10'
    Text: string;   // human readable (English)
    Origin: TAbOrigin;
  end;
  TAbMessages = array of TAbMessage;

  TAbStrings = array of string;

  { Decimal number without floating point: Value / 10^Scale. Read directly
    from the text, so '12.50' stays 12.50 (Value 1250, Scale 2). An absent
    field (Present = False, e.g. from Default()) counts as zero in arithmetic.
    Results are invalid on overflow; invalid operands give invalid results. }
  TAbDecimal = record
    Value: Int64;
    Scale: Integer;     // digits after the decimal point (0..18)
    Present: Boolean;   // the field was given (non-empty text)
    Valid: Boolean;     // well-formed number, no overflow (only meaningful if Present)
    Text: string;       // original text (trimmed), only set by Parse
    class function Parse(const s: string): TAbDecimal; static;
    class function FromInt(v: Int64; AScale: Integer = 0): TAbDecimal; static;
    function ToString: string;   // '' if absent, original text if invalid
    function IsZero: Boolean;
    function Sign: Integer;
    function Add(const b: TAbDecimal): TAbDecimal;
    function Sub(const b: TAbDecimal): TAbDecimal;
    function Mul(const b: TAbDecimal): TAbDecimal;
    function Divide(const b: TAbDecimal; Digits: Integer): TAbDecimal;
    function Rounded(Digits: Integer): TAbDecimal;  // half away from zero
    function Normalized: TAbDecimal;                // trailing zeros removed
    function Compare(const b: TAbDecimal): Integer; // -1, 0, 1
    function Equals(const b: TAbDecimal): Boolean;
    function IsUsable: Boolean;  // absent or valid: can take part in calculations
  end;

  TEInvoiceContainer = (eicontUnknown, eicontXML, eicontPDF);

  TEInvoiceSyntax = (eisynUnknown, eisynCII, eisynUBLInvoice, eisynUBLCreditNote, eisynZUGFeRD1);

  TEInvoiceProfile = (eiprofUnknown, eiprofMinimum, eiprofBasicWL, eiprofBasic, eiprofComfort,
    eiprofEN16931, eiprofExtended, eiprofXRechnung, eiprofPeppol);

  TEInvoiceAttachment = record
    Name: string;
    Description: string;
    MimeType: string;
    Relationship: string;  // AFRelationship (Alternative, Data, Source, ...)
    Size: Int64;           // -1 = unknown
    InAF: Boolean;         // listed in the catalog's /AF array (PDF/A-3)
  end;
  TEInvoiceAttachments = array of TEInvoiceAttachment;

  TEInvoiceInfo = record
    Container: TEInvoiceContainer;
    Syntax: TEInvoiceSyntax;
    Profile: TEInvoiceProfile;
    GuidelineID: string;        // BT-24 specification identifier
    XRechnungVersion: string;   // e.g. '3.0' if Profile = eiprofXRechnung
    { PDF only }
    PDFVersion: string;
    PDFAPart: string;           // from XMP, e.g. '3'
    PDFAConformance: string;    // from XMP, e.g. 'B'
    XMPDocumentType: string;
    XMPDocumentFileName: string;
    XMPVersion: string;
    XMPConformanceLevel: string;
    InvoiceFileName: string;    // name of the embedded invoice XML
    Attachments: TEInvoiceAttachments;
    { quick facts of the invoice }
    InvoiceNumber: string;      // BT-1
    IssueDate: string;          // BT-2, YYYY-MM-DD where possible
    TypeCode: string;           // BT-3
    Currency: string;           // BT-5
    SellerName: string;         // BT-27
    BuyerName: string;          // BT-44
    GrandTotal: string;         // BT-112
    DuePayable: string;         // BT-115
  end;

  { ---- Invoice model (EN 16931). Comments name the business terms. ---- }

  TEInvoiceID = record
    Value: string;
    Scheme: string;             // scheme identifier, e.g. '0088' or 'EM'
  end;
  TEInvoiceIDs = array of TEInvoiceID;

  TEInvoiceAddress = record
    Line1: string;              // BT-35 / BT-50 / BT-64 / BT-75
    Line2: string;              // BT-36 / BT-51 / BT-65 / BT-76
    Line3: string;              // BT-162 / BT-163 / BT-164 / BT-165
    City: string;               // BT-37 / BT-52 / BT-66 / BT-77
    PostCode: string;           // BT-38 / BT-53 / BT-67 / BT-78
    Subdivision: string;        // BT-39 / BT-54 / BT-68 / BT-79
    Country: string;            // BT-40 / BT-55 / BT-69 / BT-80
  end;

  TEInvoiceContact = record
    Name: string;               // BT-41 / BT-56
    Phone: string;              // BT-42 / BT-57
    Email: string;              // BT-43 / BT-58
  end;

  { Seller (BG-4), buyer (BG-7), payee (BG-10), tax representative (BG-11) }
  TEInvoiceParty = record
    Name: string;               // BT-27 / BT-44 / BT-59 / BT-62
    TradingName: string;        // BT-28 / BT-45
    IDs: TEInvoiceIDs;          // BT-29 / BT-46 / BT-60
    LegalID: TEInvoiceID;       // BT-30 / BT-47 / BT-61
    VATID: string;              // BT-31 / BT-48 / BT-63
    TaxNumber: string;          // BT-32 (seller tax registration, e.g. German Steuernummer)
    LegalInfo: string;          // BT-33
    ElectronicAddress: TEInvoiceID;  // BT-34 / BT-49
    Address: TEInvoiceAddress;  // BG-5 / BG-8 / BG-12
    Contact: TEInvoiceContact;  // BG-6 / BG-9
  end;

  TEInvoiceDelivery = record    // BG-13
    PartyName: string;          // BT-70
    LocationID: TEInvoiceID;    // BT-71
    Date: string;               // BT-72
    Address: TEInvoiceAddress;  // BG-15
  end;

  TEInvoiceNote = record        // BG-1
    SubjectCode: string;        // BT-21
    Text: string;               // BT-22
  end;
  TEInvoiceNotes = array of TEInvoiceNote;

  TEInvoiceReference = record   // BG-3 preceding invoice
    Number: string;             // BT-25
    Date: string;               // BT-26
  end;
  TEInvoiceReferences = array of TEInvoiceReference;

  TEInvoiceAccount = record     // BG-17 credit transfer
    IBAN: string;               // BT-84 (IBAN or other account identifier)
    Name: string;               // BT-85
    BIC: string;                // BT-86
  end;
  TEInvoiceAccounts = array of TEInvoiceAccount;

  TEInvoicePayment = record     // BG-16
    MeansCode: string;          // BT-81 (of the first payment means)
    MeansCodes: TAbStrings;     // codes of all payment means elements in the XML (normally one)
    MeansText: string;          // BT-82
    RemittanceInfo: string;     // BT-83
    Accounts: TEInvoiceAccounts;  // BG-17
    CardNumber: string;         // BT-87
    CardHolder: string;         // BT-88
    MandateID: string;          // BT-89
    CreditorID: string;         // BT-90
    DebitedAccount: string;     // BT-91
  end;

  { Document level: allowance BG-20 / charge BG-21; line level: BG-27 / BG-28 }
  TEInvoiceAllowanceCharge = record
    IsCharge: Boolean;
    Amount: TAbDecimal;         // BT-92 / BT-99 / BT-136 / BT-141
    BaseAmount: TAbDecimal;     // BT-93 / BT-100 / BT-137 / BT-142
    Percent: TAbDecimal;        // BT-94 / BT-101 / BT-138 / BT-143
    TaxCategory: string;        // BT-95 / BT-102 (document level only)
    TaxRate: TAbDecimal;        // BT-96 / BT-103 (document level only)
    Reason: string;             // BT-97 / BT-104 / BT-139 / BT-144
    ReasonCode: string;         // BT-98 / BT-105 / BT-140 / BT-145
  end;
  TEInvoiceAllowanceCharges = array of TEInvoiceAllowanceCharge;

  TEInvoiceTotals = record      // BG-22
    LineTotal: TAbDecimal;      // BT-106
    AllowanceTotal: TAbDecimal; // BT-107
    ChargeTotal: TAbDecimal;    // BT-108
    TaxExclusive: TAbDecimal;   // BT-109
    TaxTotal: TAbDecimal;       // BT-110
    TaxTotalTaxCurrency: TAbDecimal;  // BT-111
    TaxInclusive: TAbDecimal;   // BT-112
    Prepaid: TAbDecimal;        // BT-113
    Rounding: TAbDecimal;       // BT-114
    DuePayable: TAbDecimal;     // BT-115
  end;

  TEInvoiceTax = record         // BG-23
    TaxableAmount: TAbDecimal;  // BT-116
    TaxAmount: TAbDecimal;      // BT-117
    Category: string;           // BT-118
    Rate: TAbDecimal;           // BT-119
    ExemptionReason: string;    // BT-120
    ExemptionReasonCode: string;  // BT-121
  end;
  TEInvoiceTaxes = array of TEInvoiceTax;

  TEInvoiceDocument = record    // BG-24 additional supporting document
    ID: string;                 // BT-122
    Description: string;        // BT-123
    URI: string;                // BT-124
    Content: TBytes;            // BT-125 (decoded)
    MimeType: string;           // BT-125-1
    FileName: string;           // BT-125-2
  end;
  TEInvoiceDocuments = array of TEInvoiceDocument;

  TEInvoiceFileSource = (eisrcPDF, eisrcInvoice);

  { A file that comes with the invoice, with its content: an embedded file of
    the PDF (eisrcPDF, including the invoice XML itself) or a supporting
    document of the invoice (eisrcInvoice, BG-24). }
  TEInvoiceFile = record
    Source: TEInvoiceFileSource;
    Name: string;           // file name as given: PDF /UF or /F; BG-24 BT-125-2 (may be empty)
    Description: string;    // PDF /Desc; BG-24 BT-123
    MimeType: string;       // PDF /Subtype; BG-24 BT-125-1
    Relationship: string;   // PDF AFRelationship
    ID: string;             // BG-24 BT-122
    URI: string;            // BG-24 BT-124: external document, no content
    IsInvoice: Boolean;     // PDF: this embedded file is the invoice XML
    Content: TBytes;        // empty for external documents or unreadable streams
  end;
  TEInvoiceFiles = array of TEInvoiceFile;

  TEInvoiceItemAttribute = record  // BG-32
    Name: string;               // BT-160
    Value: string;              // BT-161
  end;
  TEInvoiceItemAttributes = array of TEInvoiceItemAttribute;

  TEInvoiceLine = record        // BG-25
    ID: string;                 // BT-126
    ParentID: string;           // sub-line (XRechnung extension): ID of the parent line
    Note: string;               // BT-127
    ObjectID: TEInvoiceID;      // BT-128
    Quantity: TAbDecimal;       // BT-129
    UnitCode: string;           // BT-130
    NetAmount: TAbDecimal;      // BT-131
    OrderLineRef: string;       // BT-132
    AccountingRef: string;      // BT-133
    PeriodStart: string;        // BT-134
    PeriodEnd: string;          // BT-135
    AllowancesCharges: TEInvoiceAllowanceCharges;  // BG-27, BG-28
    NetPrice: TAbDecimal;       // BT-146
    PriceDiscount: TAbDecimal;  // BT-147
    GrossPrice: TAbDecimal;     // BT-148
    BaseQuantity: TAbDecimal;   // BT-149
    BaseQuantityUnit: string;   // BT-150
    TaxCategory: string;        // BT-151
    TaxRate: TAbDecimal;        // BT-152
    ItemName: string;           // BT-153
    ItemDescription: string;    // BT-154
    SellerItemID: string;       // BT-155
    BuyerItemID: string;        // BT-156
    StandardItemID: TEInvoiceID;    // BT-157
    Classifications: TEInvoiceIDs;  // BT-158
    OriginCountry: string;      // BT-159
    Attributes: TEInvoiceItemAttributes;  // BG-32
  end;
  TEInvoiceLines = array of TEInvoiceLine;

  TEInvoice = record
    Info: TEInvoiceInfo;        // container, syntax, profile, PDF facts
    Number: string;             // BT-1
    IssueDate: string;          // BT-2 (dates as YYYY-MM-DD where possible)
    TypeCode: string;           // BT-3
    Currency: string;           // BT-5
    TaxCurrency: string;        // BT-6
    TaxPointDate: string;       // BT-7
    TaxPointDateCode: string;   // BT-8 (UNTDID 2005: 3, 35, 432)
    DueDate: string;            // BT-9
    BuyerReference: string;     // BT-10 (Leitweg-ID)
    ProjectRef: string;         // BT-11
    ContractRef: string;        // BT-12
    OrderRef: string;           // BT-13
    SalesOrderRef: string;      // BT-14
    ReceivingAdviceRef: string; // BT-15
    DespatchAdviceRef: string;  // BT-16
    TenderRef: string;          // BT-17
    InvoicedObject: TEInvoiceID;  // BT-18
    AccountingRef: string;      // BT-19
    PaymentTerms: string;       // BT-20 (untrimmed: line breaks matter for XRechnung Skonto)
    Notes: TEInvoiceNotes;      // BG-1
    BusinessProcess: string;    // BT-23
    Specification: string;      // BT-24
    PrecedingInvoices: TEInvoiceReferences;  // BG-3
    Seller: TEInvoiceParty;     // BG-4
    Buyer: TEInvoiceParty;      // BG-7
    Payee: TEInvoiceParty;      // BG-10
    TaxRepresentative: TEInvoiceParty;  // BG-11
    Delivery: TEInvoiceDelivery;  // BG-13
    PeriodStart: string;        // BT-73
    PeriodEnd: string;          // BT-74
    Payment: TEInvoicePayment;  // BG-16
    AllowancesCharges: TEInvoiceAllowanceCharges;  // BG-20, BG-21
    Totals: TEInvoiceTotals;    // BG-22
    Taxes: TEInvoiceTaxes;      // BG-23
    Documents: TEInvoiceDocuments;  // BG-24
    Lines: TEInvoiceLines;      // BG-25
    { XML content that has no place in the model (e.g. EXTENDED fields),
      as 'path = value' with local element names }
    Unmapped: TAbStrings;
  end;

  { What became of one rule of the check for an invoice. Applied means: the
    invoice contains what the rule is about and abdecker could decide it
    (rules that cannot be decided reliably stay not applied, see NotChecked). }
  TAbRuleStatus = (arsNotApplied, arsPassed, arsFailed);

  TAbRuleResult = record
    ID: string;              // rule ID, e.g. 'BR-CO-10'
    Status: TAbRuleStatus;
    Origin: TAbOrigin;       // aboOfficial; aboExtra for own rules and rules applied beyond their rule set
  end;
  TAbRuleResults = array of TAbRuleResult;

  { Result of the plausibility check }
  TAbCheckReport = record
    Messages: TAbMessages;      // findings, Code = rule ID (e.g. 'BR-CO-10'), plus load messages
    Errors: Integer;            // messages with severity abError
    Warnings: Integer;          // messages with severity abWarning
    RuleSets: TAbStrings;       // applied rule sets, e.g. 'EN 16931', 'XRechnung 3.0'
    NotChecked: TAbStrings;     // what this invoice contains but the check does not cover
    { every rule of the applied rule sets plus rules applied as extra
      checks, ordered by ID (numbers by value: BR-DE-2 before BR-DE-10);
      empty if no rule set was applied }
    Rules: TAbRuleResults;
    { True if there is a finding of at least MinSeverity: abError = errors
      only (the default meaning of "failed"), abWarning = errors or warnings,
      abInfo = any message. NotChecked never counts. }
    function Failed(MinSeverity: TAbSeverity = abError): Boolean;
  end;

  { Options for InvoiceFromJson }
  TAbJsonOptions = record
    Today: string;      // YYYY-MM-DD for {{today}} and the default issue date; '' = system date
    Vars: TAbStrings;   // placeholder values 'name=value'; they take precedence over the built-ins
    BaseDir: string;    // folder for attachments given as "file"; '' = not allowed (e.g. server)
  end;

  TAbdecker = class
  public
    { Analyse a PDF or XML file: container, syntax, profile, attachments. }
    class function Info(const FileName: string; out AInfo: TEInvoiceInfo;
      out Msgs: TAbMessages): TAbResult; static;
    class function InfoFromBytes(const Data: TBytes; out AInfo: TEInvoiceInfo;
      out Msgs: TAbMessages): TAbResult; static;

    { Extract the invoice XML embedded in a ZUGFeRD/Factur-X PDF. The bytes
      are returned unchanged, even if the XML itself is broken. }
    class function ExtractXML(const FileName: string; out Xml: TBytes;
      out XmlName: string; out Msgs: TAbMessages): TAbResult; static;
    class function ExtractXMLFromBytes(const Data: TBytes; out Xml: TBytes;
      out XmlName: string; out Msgs: TAbMessages): TAbResult; static;

    { Read a complete invoice (PDF or XML) into the model. Inv.Info is filled
      as by Info. Malformed numbers are reported, everything else is left to
      the plausibility check. }
    class function Load(const FileName: string; out Inv: TEInvoice;
      out Msgs: TAbMessages): TAbResult; static;
    class function LoadFromBytes(const Data: TBytes; out Inv: TEInvoice;
      out Msgs: TAbMessages): TAbResult; static;

    { Plausibility check of a loaded invoice: EN 16931 rules, code lists and,
      for XRechnung 3.0, the national rules. Returns True if no errors were
      found (warnings are allowed). Only fully implemented rules report;
      Report.NotChecked lists what could not be checked for this invoice. }
    class function Check(const Inv: TEInvoice; out Report: TAbCheckReport): Boolean; static;
    { Load and check in one go; load messages (e.g. PDF/A) are part of the report }
    class function CheckFile(const FileName: string; out Inv: TEInvoice;
      out Report: TAbCheckReport): TAbResult; static;
    class function CheckBytes(const Data: TBytes; out Inv: TEInvoice;
      out Report: TAbCheckReport): TAbResult; static;

    { Embed a CII invoice into an existing PDF (ZUGFeRD / Factur-X) by an
      incremental update: embedded file, /AF, XMP with the Factur-X schema.
      The XML is embedded unchanged, the original bytes stay untouched. The
      PDF is not converted to PDF/A; if it is not PDF/A already, a warning
      says so. UBL is converted to CII first (same content, both are
      bindings of EN 16931; info EMBED-UBL): what lies outside EN 16931 is
      lost (warning EMBED-UBL-LOST), Peppol BIS is embedded as EN 16931
      (info EMBED-PEPPOL). The result is read back and compared before it
      is returned. }
    class function Embed(const PdfFile, XmlFile, OutFile: string;
      out Msgs: TAbMessages): TAbResult; static;
    class function EmbedBytes(const Pdf, Xml: TBytes; out OutPdf: TBytes;
      out Msgs: TAbMessages): TAbResult; static;

    { Remove the invoice XML from a ZUGFeRD/Factur-X PDF, the counterpart of
      Embed: an incremental update takes the file out of the embedded files
      and /AF, and the ZUGFeRD/Factur-X properties out of the XMP metadata.
      Other attachments stay. The data of the XML is then overwritten in place
      (it is no longer referenced; same length, so the file structure stays
      valid). Exceptions, each with an info message: signed PDFs (the
      signature covers those bytes) and PDFs in which other parts still refer
      to the file; there the XML stays in the earlier revision of the file.
      XmlName: the name of the removed file. }
    class function Strip(const PdfFile, OutFile: string; out XmlName: string;
      out Msgs: TAbMessages): TAbResult; static;
    class function StripBytes(const Pdf: TBytes; out OutPdf: TBytes; out XmlName: string;
      out Msgs: TAbMessages): TAbResult; static;

    { Add files to an invoice XML (CII or UBL) as supporting documents
      (BG-24, embedded base64). Per document Content and FileName are needed
      (a path in FileName is dropped);
      ID defaults to the file name, MimeType to the type derived from the file
      extension. Allowed types (EN 16931): PDF, PNG, JPEG, CSV, XLSX, ODS.
      Not for the CII profiles MINIMUM, BASIC WL and BASIC, which have no
      attachments. The XML is not rebuilt: the documents are inserted as text,
      everything else stays byte for byte. Attach takes file names. }
    class function Attach(const XmlFile: string; const Files: array of string;
      const OutFile: string; out Msgs: TAbMessages): TAbResult; static;
    class function AttachBytes(const Xml: TBytes; const Docs: TEInvoiceDocuments;
      out OutXml: TBytes; out Msgs: TAbMessages): TAbResult; static;

    { All files that come with an invoice, with content: for a PDF its
      embedded files (the invoice XML marked IsInvoice) and the supporting
      documents (BG-24) of the invoice; for an XML its BG-24 documents.
      A PDF without invoice is fine (abOK, its embedded files). }
    class function Attachments(const FileName: string; out Files: TEInvoiceFiles;
      out Msgs: TAbMessages): TAbResult; static;
    class function AttachmentsFromBytes(const Data: TBytes; out Files: TEInvoiceFiles;
      out Msgs: TAbMessages): TAbResult; static;

    { The invoice model as CII (UN/CEFACT D16B, as used by ZUGFeRD 2,
      Factur-X and XRechnung). The writer puts out every filled field of the
      model as it is: no calculation, no defaults, no decisions (the profile
      comes from Inv.Specification). The result is read back and must give
      the same model, else nothing is returned (abInternalError). Then it is
      checked: Report holds the findings, the XML is returned anyway (abOK);
      whether check errors stop is up to the caller (Report.Failed). }
    class function WriteCII(const Inv: TEInvoice; out Xml: TBytes;
      out Report: TAbCheckReport): TAbResult; static;

    { An invoice in the own JSON format (see templates/) as model, ready for
      WriteCII: placeholders (today, own variables) replaced, defaults and
      calculated values filled in (line numbers, line amounts, VAT
      breakdown, totals, rounding). Errors of the format (JSON syntax,
      unknown or duplicate fields, wrong types, unusable numbers or dates,
      unknown placeholders, given totals that differ ...) give abInvalidData,
      each message with line and column. Whether the invoice is complete is
      up to the check (WriteCII). }
    class function InvoiceFromJson(const Json: TBytes; const Options: TAbJsonOptions;
      out Inv: TEInvoice; out Msgs: TAbMessages): TAbResult; static;
    { Placeholder values from a JSON object ('name=value' for TAbJsonOptions.Vars):
      only the strings and numbers at the top level, everything else is
      ignored. abInvalidData if the JSON is broken or not an object. }
    class function VarsFromJson(const Json: TBytes; out Vars: TAbStrings;
      out Msgs: TAbMessages): TAbResult; static;

    { The invoice as a standalone HTML page (CSS inside, no JavaScript).
      Lang: 'de' or 'en'. WithCheck: show the result of the plausibility check.
      Below the totals, what is to be paid; for a credit transfer like a
      transfer form, with GiroCode. PaymentOnly: a page with just that (and
      the check result), to print or for the viewer. }
    class function ToHtml(const Inv: TEInvoice; const Lang: string = 'de';
      WithCheck: Boolean = true; PaymentOnly: Boolean = false): string; static;
    { The text of the GiroCode (EPC QR code, version 002, UTF-8) to pay the
      invoice by SEPA credit transfer; '' if there is none: not a credit
      transfer, not EUR, no valid IBAN, nothing due, credit note. Draw it with
      QrCodeSvg. }
    class function GiroCode(const Inv: TEInvoice): string; static;
    { A QR code as SVG: the text as UTF-8 in byte mode, error correction
      level M (as the GiroCode demands), quiet zone of four modules. '' if the
      text is too long (more than 2331 bytes). }
    class function QrCodeSvg(const Text: string): string; static;

    { Results as JSON: the common format of the command line (--json) and the
      server. Fields are only ever added, never renamed. FileName goes into
      the field "file" (may be empty). MessagesToJson: result code and
      messages only, e.g. for errors or binary results. }
    class function InfoToJson(const FileName: string; r: TAbResult; const AInfo: TEInvoiceInfo;
      const Msgs: TAbMessages): string; static;
    { WithRules: also the field "rules", the status of every rule (Report.Rules) }
    class function CheckToJson(const FileName: string; r: TAbResult; const Inv: TEInvoice;
      const Report: TAbCheckReport; WithRules: Boolean = false): string; static;
    { Attachments as JSON; WithContent: the content base64-encoded in "content" }
    class function AttachmentsToJson(const FileName: string; r: TAbResult; const Files: TEInvoiceFiles;
      const Msgs: TAbMessages; WithContent: Boolean = false): string; static;
    { The invoice for further processing (accounting import, scripts): a
      reduced, flat view, not the whole model. Field names as in the own
      format (InvoiceFromJson) where the meaning is the same, plus line
      amounts, VAT breakdown, document level allowances and charges, payment
      means, prepaid amount, attachments as metadata. Empty fields are left
      out, amounts are JSON numbers exactly as in the invoice. Not meant as
      input for InvoiceFromJson. Msgs: those of loading. }
    class function InvoiceToJson(const FileName: string; r: TAbResult; const Inv: TEInvoice;
      const Msgs: TAbMessages): string; static;
    class function MessagesToJson(r: TAbResult; const Msgs: TAbMessages): string; overload; static;
    { The same with a result word of the caller, e.g. 'not-found' (serve) }
    class function MessagesToJson(const AResult: string; const Msgs: TAbMessages): string; overload; static;

    { Stable code words as used in the JSON output, e.g. 'no-invoice',
      'xrechnung', 'warning', 'extra'. }
    class function ResultCode(r: TAbResult): string; static;
    class function SyntaxCode(s: TEInvoiceSyntax): string; static;
    class function ProfileCode(p: TEInvoiceProfile): string; static;
    class function ContainerCode(c: TEInvoiceContainer): string; static;
    class function SeverityCode(s: TAbSeverity): string; static;
    class function OriginCode(o: TAbOrigin): string; static;
    class function RuleStatusCode(s: TAbRuleStatus): string; static;

    class function ResultText(r: TAbResult): string; static;
    class function SyntaxName(s: TEInvoiceSyntax): string; static;
    class function ProfileName(p: TEInvoiceProfile): string; static;
    class function TypeCodeName(const Code: string): string; static;
  end;


implementation

uses
{$IF DEFINED(FPC) and DEFINED(UNIX)}
  cwstring,  // UTF-8 <-> UnicodeString (literals with umlauts are UnicodeString)
{$IFEND}
  abdecker.util, abdecker.xml, abdecker.read, abdecker.cii, abdecker.check, abdecker.embed, abdecker.html,
  abdecker.attach, abdecker.json, abdecker.format, abdecker.payment, abdecker.qr;

{ ===========================================================================
  Decimal numbers
  =========================================================================== }

const
  MaxScale = 18;
  Pow10: array[0..MaxScale] of Int64 = (1, 10, 100, 1000, 10000, 100000,
    1000000, 10000000, 100000000, 1000000000, 10000000000, 100000000000,
    1000000000000, 10000000000000, 100000000000000, 1000000000000000,
    10000000000000000, 100000000000000000, 1000000000000000000);

function MulChk(a, b: Int64; out r: Int64): Boolean;
begin
  r := 0;
  if (a = 0) or (b = 0) then exit(true);
  if (a = Low(Int64)) or (b = Low(Int64)) or (Abs(a) > High(Int64) div Abs(b)) then exit(false);
  r := a * b;
  result := true;
end;

function AddChk(a, b: Int64; out r: Int64): Boolean;
begin
  r := 0;
  if ((b > 0) and (a > High(Int64) - b)) or ((b < 0) and (a < Low(Int64) - b)) then exit(false);
  r := a + b;
  result := true;
end;

function DecInvalid: TAbDecimal;
begin
  result := Default(TAbDecimal);
  result.Present := true;
  result.Text := '?';
end;

{ Brings A and B to the larger of both scales. }
function AlignScale(var a, b: TAbDecimal): Boolean;
var
  v: Int64;
begin
  result := true;

  if a.Scale < b.Scale then begin
    result := (b.Scale - a.Scale <= MaxScale) and MulChk(a.Value, Pow10[b.Scale - a.Scale], v);
    a.Value := v;
    a.Scale := b.Scale;
  end else if b.Scale < a.Scale then begin
    result := (a.Scale - b.Scale <= MaxScale) and MulChk(b.Value, Pow10[a.Scale - b.Scale], v);
    b.Value := v;
    b.Scale := a.Scale;
  end;
end;

{ Q := N / D rounded half away from zero }
function DivRound(n, d: Int64): Int64;
var
  r: Int64;
begin
  result := n div d;
  r := Abs(n mod d);
  if r >= Abs(d) - r then begin
    if (n < 0) <> (d < 0) then begin
      Dec(result);
    end else begin
      Inc(result);
    end;
  end;
end;

class function TAbDecimal.Parse(const s: string): TAbDecimal;
var
  i, n, sig: Integer;
  neg, dot: Boolean;
  intPart, frac, digits: string;
  v: Int64;
  c: Char;
begin
  result := Default(TAbDecimal);
  result.Text := Trim(s);
  result.Valid := true;
  n := Length(result.Text);
  if n = 0 then exit;
  result.Present := true;
  result.Valid := false;
  i := 1;
  neg := false;
  c := result.Text[1];
  if (c = '+') or (c = '-') then begin
    neg := c = '-';
    Inc(i);
  end;

  intPart := '';
  frac := '';
  dot := false;

  while i <= n do begin
    c := result.Text[i];
    if (c >= '0') and (c <= '9') then begin
      if dot then begin
        frac := frac + c;
      end else begin
        intPart := intPart + c;
      end;
    end else if (c = '.') and not dot then begin
      dot := true;
    end else begin
      exit;
    end;

    Inc(i);
  end;

  if intPart + frac = '' then exit;
  // trailing zeros of the fraction carry no value: drop them if they don't fit
  digits := intPart + frac;
  sig := Length(digits);
  i := 1;
  while (i < sig) and (digits[i] = '0') do begin
    Inc(i);
  end;

  sig := sig - i + 1;
  while ((sig > 18) or (Length(frac) > MaxScale)) and (frac <> '') and (frac[Length(frac)] = '0') do begin
    SetLength(frac, Length(frac) - 1);
    Dec(sig);
  end;

  if (sig > 18) or (Length(frac) > MaxScale) then exit;
  v := 0;
  digits := intPart + frac;

  for i := 1 to Length(digits) do begin
    v := v * 10 + (Ord(digits[i]) - Ord('0'));
  end;

  if neg then v := -v;
  result.Value := v;
  result.Scale := Length(frac);
  result.Valid := true;
end;

class function TAbDecimal.FromInt(v: Int64; AScale: Integer): TAbDecimal;
begin
  result := Default(TAbDecimal);
  result.Value := v;
  result.Scale := AScale;
  result.Present := true;
  result.Valid := true;
end;

function TAbDecimal.ToString: string;
var
  s: string;
begin
  if not Present then exit('');
  if not Valid or (Value = Low(Int64)) then exit(Text);
  s := IntToStr(Abs(Value));

  if Scale > 0 then begin
    while Length(s) <= Scale do begin
      s := '0' + s;
    end;

    s := Copy(s, 1, Length(s) - Scale) + '.' + Copy(s, Length(s) - Scale + 1, Scale);
  end;

  if Value < 0 then s := '-' + s;
  result := s;
end;

function TAbDecimal.IsUsable: Boolean;
begin
  result := Valid or not Present;
end;

function TAbDecimal.IsZero: Boolean;
begin
  result := Value = 0;
end;

function TAbDecimal.Sign: Integer;
begin
  if Value < 0 then result := -1
  else if Value > 0 then result := 1
  else result := 0;
end;

function TAbDecimal.Add(const b: TAbDecimal): TAbDecimal;
var
  x, y: TAbDecimal;
  v: Int64;
begin
  if not (IsUsable and b.IsUsable) then exit(DecInvalid);
  x := Self;
  y := b;
  if not AlignScale(x, y) or not AddChk(x.Value, y.Value, v) then exit(DecInvalid);
  result := FromInt(v, x.Scale);
end;

function TAbDecimal.Sub(const b: TAbDecimal): TAbDecimal;
var
  y: TAbDecimal;
begin
  y := b;
  y.Value := -y.Value;
  result := Add(y);
end;

function TAbDecimal.Mul(const b: TAbDecimal): TAbDecimal;
var
  v: Int64;
begin
  if not (IsUsable and b.IsUsable) or not MulChk(Value, b.Value, v) then exit(DecInvalid);
  result := FromInt(v, Scale + b.Scale);
  if result.Scale > MaxScale then result := result.Rounded(MaxScale);
end;

function TAbDecimal.Divide(const b: TAbDecimal; Digits: Integer): TAbDecimal;
var
  e: Integer;
  n, d: Int64;
begin
  if not (IsUsable and b.IsUsable) or (b.Value = 0) or (Digits < 0) or (Digits > MaxScale) then begin
    exit(DecInvalid);
  end;
  // (Value / 10^Scale) / (B.Value / 10^B.Scale), result scaled by 10^Digits
  e := b.Scale - Scale + Digits;
  n := Value;
  d := b.Value;

  if e >= 0 then begin
    if (e > MaxScale) or not MulChk(n, Pow10[e], n) then exit(DecInvalid);
  end else if (-e > MaxScale) or not MulChk(d, Pow10[-e], d) then exit(DecInvalid);

  result := FromInt(DivRound(n, d), Digits);
end;

function TAbDecimal.Rounded(Digits: Integer): TAbDecimal;
begin
  result := Self;
  result.Text := '';
  if not Valid then exit(Self);
  if Digits < 0 then Digits := 0;

  while result.Scale - Digits > MaxScale do begin
    result.Value := result.Value div 10;
    Dec(result.Scale);
  end;

  if result.Scale <= Digits then exit;
  result.Value := DivRound(result.Value, Pow10[result.Scale - Digits]);
  result.Scale := Digits;
end;

function TAbDecimal.Normalized: TAbDecimal;
begin
  result := Self;
  if not Valid then exit;
  result.Text := '';

  while (result.Scale > 0) and (result.Value mod 10 = 0) do begin
    result.Value := result.Value div 10;
    Dec(result.Scale);
  end;
end;

function TAbDecimal.Compare(const b: TAbDecimal): Integer;
var
  x, y: TAbDecimal;
begin
  x := Self;
  y := b;
  if not AlignScale(x, y) then begin
    // very different magnitudes: integer parts decide
    x.Value := Value div Pow10[Scale];
    y.Value := b.Value div Pow10[b.Scale];
  end;

  if x.Value < y.Value then result := -1
  else if x.Value > y.Value then result := 1
  else result := 0;
end;

function TAbDecimal.Equals(const b: TAbDecimal): Boolean;
begin
  result := Compare(b) = 0;
end;

{ ===========================================================================
  Public API
  =========================================================================== }

class function TAbdecker.Info(const FileName: string; out AInfo: TEInvoiceInfo; out Msgs: TAbMessages): TAbResult;
var
  data, xml: TBytes;
  doc: TXDoc;
begin
  AInfo := Default(TEInvoiceInfo);
  Msgs := nil;
  if not ReadAllBytes(FileName, data, Msgs) then exit(abFileError);
  result := SafeAnalyze(data, AInfo, xml, doc, Msgs);
end;

class function TAbdecker.InfoFromBytes(const Data: TBytes; out AInfo: TEInvoiceInfo; out Msgs: TAbMessages): TAbResult;
var
  xml: TBytes;
  doc: TXDoc;
begin
  AInfo := Default(TEInvoiceInfo);
  Msgs := nil;
  result := SafeAnalyze(Data, AInfo, xml, doc, Msgs);
end;

class function TAbdecker.ExtractXMLFromBytes(const Data: TBytes; out Xml: TBytes; out XmlName: string;
  out Msgs: TAbMessages): TAbResult;
var
  info: TEInvoiceInfo;
  doc: TXDoc;
begin
  Msgs := nil;
  XmlName := '';
  info := Default(TEInvoiceInfo);
  result := SafeAnalyze(Data, info, Xml, doc, Msgs);

  if info.Container = eicontXML then begin
    Xml := nil;
    AddMsg(Msgs, abError, 'EXTRACT-XML', 'The input is already XML, there is nothing to extract');
    exit(abUnsupported);
  end;

  if (info.Container = eicontPDF) and (Length(Xml) > 0) then begin
    // the embedded XML is returned even if it is broken or of unknown type
    XmlName := info.InvoiceFileName;
    result := abOK;
  end else begin
    Xml := nil;
  end;
end;

class function TAbdecker.ExtractXML(const FileName: string; out Xml: TBytes; out XmlName: string;
  out Msgs: TAbMessages): TAbResult;
var
  data: TBytes;
  m: TAbMessages;
begin
  Xml := nil;
  XmlName := '';
  m := nil;
  if not ReadAllBytes(FileName, data, m) then begin
    Msgs := m;
    exit(abFileError);
  end;

  result := ExtractXMLFromBytes(data, Xml, XmlName, Msgs);
end;

class function TAbdecker.LoadFromBytes(const Data: TBytes; out Inv: TEInvoice;
  out Msgs: TAbMessages): TAbResult;
var
  xml: TBytes;
  doc: TXDoc;
begin
  Inv := Default(TEInvoice);
  Msgs := nil;
  result := SafeAnalyze(Data, Inv.Info, xml, doc, Msgs);
  if result <> abOK then exit;

  try
    ReadModel(doc, Inv, Msgs);
  except
    on e: Exception do begin
      AddMsg(Msgs, abError, 'INTERNAL', 'Internal error: ' + e.Message);
      result := abInternalError;
    end;
  end;
end;

class function TAbdecker.Load(const FileName: string; out Inv: TEInvoice;
  out Msgs: TAbMessages): TAbResult;
var
  data: TBytes;
  m: TAbMessages;
begin
  m := nil;
  if not ReadAllBytes(FileName, data, m) then begin
    Inv := Default(TEInvoice);
    Msgs := m;
    exit(abFileError);
  end;

  result := LoadFromBytes(data, Inv, Msgs);
end;

procedure CountMessages(var Report: TAbCheckReport);
var
  i: Integer;
begin
  Report.Errors := 0;
  Report.Warnings := 0;

  for i := 0 to High(Report.Messages) do begin
    case Report.Messages[i].Severity of
      abError: Inc(Report.Errors);
      abWarning: Inc(Report.Warnings);
    end;
  end;
end;

class function TAbdecker.Check(const Inv: TEInvoice; out Report: TAbCheckReport): Boolean;
begin
  Report := Default(TAbCheckReport);

  try
    CheckInvoice(Inv, Report);
  except
    on e: Exception do
      AddMsg(Report.Messages, abError, 'INTERNAL', 'Internal error: ' + e.Message);
  end;

  CountMessages(Report);
  result := Report.Errors = 0;
end;

class function TAbdecker.CheckBytes(const Data: TBytes; out Inv: TEInvoice;
  out Report: TAbCheckReport): TAbResult;
var
  msgs: TAbMessages;
begin
  Report := Default(TAbCheckReport);
  result := LoadFromBytes(Data, Inv, msgs);
  if result = abOK then begin
    Check(Inv, Report);
  end;
  // load messages first, then the findings
  Report.Messages := Concat(msgs, Report.Messages);
  CountMessages(Report);
end;

class function TAbdecker.CheckFile(const FileName: string; out Inv: TEInvoice;
  out Report: TAbCheckReport): TAbResult;
var
  data: TBytes;
begin
  Report := Default(TAbCheckReport);
  if not ReadAllBytes(FileName, data, Report.Messages) then begin
    Inv := Default(TEInvoice);
    CountMessages(Report);
    exit(abFileError);
  end;

  result := CheckBytes(data, Inv, Report);
end;

function SameBytes(const a, b: TBytes): Boolean;
begin
  result := (Length(a) = Length(b)) and ((Length(a) = 0) or CompareMem(@a[0], @b[0], Length(a)));
end;

{ UBL -> model -> CII for embedding: both are bindings of EN 16931, so the
  content stays the same (WriteCII checks that). Lost: what lies outside
  EN 16931 (not mapped by the reader), with a warning. Peppol BIS is no
  ZUGFeRD/Factur-X profile: such an invoice also meets EN 16931 (Peppol is
  a CIUS of it), so it is embedded as EN 16931, with a note. }
function UblToCii(const Ubl: TBytes; out Cii: TBytes; var Msgs: TAbMessages): TAbResult;
const
  SpecEN16931 = 'urn:cen.eu:en16931:2017';
var
  inv: TEInvoice;
  rep: TAbCheckReport;
  m: TAbMessages;
  lost: TStringList;
  i, p: Integer;
  s: string;
begin
  Cii := nil;
  result := TAbdecker.LoadFromBytes(Ubl, inv, m);

  if result <> abOK then begin
    Msgs := Concat(Msgs, m);
    exit;
  end;

  if inv.Info.Profile = eiprofPeppol then begin
    AddMsg(Msgs, abInfo, 'EMBED-PEPPOL', Format('Peppol BIS is no ZUGFeRD/Factur-X profile; embedded as ' +
      'EN 16931 (specification identifier BT-24 "%s" instead of "%s"), which every Peppol BIS invoice ' +
      'also meets', [SpecEN16931, inv.Specification]));
    inv.Specification := SpecEN16931;
  end;

  if Length(inv.Unmapped) > 0 then begin
    lost := TStringList.Create;

    try
      lost.Sorted := true;
      lost.Duplicates := dupIgnore;

      for i := 0 to High(inv.Unmapped) do begin
        s := inv.Unmapped[i];
        p := Pos(' = ', s);
        if p > 0 then s := Copy(s, 1, p - 1);
        lost.Add(s);
      end;

      s := '';

      for i := 0 to lost.Count - 1 do begin
        if s <> '' then s := s + ', ';
        s := s + lost[i];
      end;
    finally
      lost.Free;
    end;

    AddMsg(Msgs, abWarning, 'EMBED-UBL-LOST',
      'Content of the UBL outside EN 16931 has no place in CII and is left out: ' + s);
  end;

  result := TAbdecker.WriteCII(inv, Cii, rep);

  if result <> abOK then begin
    for i := 0 to High(rep.Messages) do begin
      if rep.Messages[i].Origin = aboFile then AddMsg(Msgs, rep.Messages[i].Severity, rep.Messages[i].Code,
        rep.Messages[i].Text);
    end;

    Cii := nil;
    exit;
  end;

  AddMsg(Msgs, abInfo, 'EMBED-UBL', 'UBL converted to CII (the same content according to EN 16931); ' +
    'the PDF contains the CII');
end;

class function TAbdecker.EmbedBytes(const Pdf, Xml: TBytes; out OutPdf: TBytes;
  out Msgs: TAbMessages): TAbResult;
var
  xmpMsg: Boolean;
  xi, pi, vi: TEInvoiceInfo;
  m: TAbMessages;
  r: TAbResult;
  name, level, rel, vName: string;
  inv: TEInvoice;
  rep: TAbCheckReport;
  back, x: TBytes;
  i: Integer;
begin
  OutPdf := nil;
  Msgs := nil;
  x := Xml;

  try
    // the invoice: CII with a known profile (UBL is converted)
    r := InfoFromBytes(x, xi, m);
    if (r <> abOK) and (xi.Container <> eicontPDF) then begin
      Msgs := m;
      exit(r);
    end;

    if xi.Container <> eicontXML then begin
      AddMsg(Msgs, abError, 'EMBED-NOT-XML', 'The invoice must be an XML file');
      exit(abUnsupported);
    end;

    if xi.Syntax in [eisynUBLInvoice, eisynUBLCreditNote] then begin
      r := UblToCii(Xml, x, Msgs);
      if r <> abOK then exit(r);
      InfoFromBytes(x, xi, m);
    end;

    if xi.Syntax <> eisynCII then begin
      AddMsg(Msgs, abError, 'EMBED-SYNTAX', 'Only CII according to ZUGFeRD 2 / Factur-X can be embedded');
      exit(abUnsupported);
    end;

    rel := 'Alternative';

    case xi.Profile of
      eiprofMinimum: begin level := 'MINIMUM'; rel := 'Data'; end;
      eiprofBasicWL: begin level := 'BASIC WL'; rel := 'Data'; end;
      eiprofBasic: level := 'BASIC';
      eiprofComfort, eiprofEN16931: level := 'EN 16931';
      eiprofExtended: level := 'EXTENDED';
      eiprofXRechnung: level := 'XRECHNUNG';
    else
      AddMsg(Msgs, abError, 'EMBED-PROFILE',
        Format('The invoice profile is unknown (identifier "%s")', [xi.GuidelineID]));
      exit(abUnsupported);
    end;

    if xi.Profile = eiprofXRechnung then begin
      name := 'xrechnung.xml';
    end else begin
      name := 'factur-x.xml';
    end;

    // the PDF: readable, no invoice inside yet
    r := InfoFromBytes(Pdf, pi, m);

    if pi.Container <> eicontPDF then begin
      AddMsg(Msgs, abError, 'EMBED-NOT-PDF', 'The first file is not a PDF');
      exit(abUnsupported);
    end;

    for i := 0 to High(m) do begin
      if m[i].Code = 'PDF-XREF' then begin
        AddMsg(Msgs, abError, 'EMBED-BROKEN',
          'The PDF structure is broken, an update cannot be appended safely');
        exit(abBrokenPDF);
      end;
    end;

    if r = abOK then begin
      AddMsg(Msgs, abError, 'EMBED-EXISTS',
        Format('The PDF already contains an e-invoice (%s)', [pi.InvoiceFileName]));
      exit(abUnsupported);
    end;

    if r <> abNoInvoice then begin
      Msgs := m;
      exit(r);
    end;

    // hints that do not stop us
    if pi.PDFAPart = '' then begin
      AddMsg(Msgs, abWarning, 'EMBED-NO-PDFA',
        'The PDF is not PDF/A. ZUGFeRD/Factur-X require PDF/A-3; the result contains ' +
        'the invoice and its metadata but is formally not a valid ZUGFeRD PDF.');
    end;

    if LoadFromBytes(x, inv, m) = abOK then begin
      Check(inv, rep);

      if rep.Errors > 0 then begin
        AddMsg(Msgs, abWarning, 'EMBED-CHECK',
          Format('The invoice has %d check error(s) (details: abdecker check)', [rep.Errors]));
      end;
    end;

    r := EmbedInvoice(Pdf, x, name, level, rel, pi.PDFAPart, OutPdf, Msgs);
    if r <> abOK then begin
      OutPdf := nil;
      exit(r);
    end;

    // read the result back: it must contain exactly this invoice
    r := ExtractXMLFromBytes(OutPdf, back, vName, m);
    InfoFromBytes(OutPdf, vi, m);

    if (r <> abOK) or not SameBytes(back, x) or (vName <> name) or (vi.Profile <> xi.Profile) then begin
      OutPdf := nil;
      AddMsg(Msgs, abError, 'EMBED-VERIFY', 'The generated PDF fails the self-check (please report)');
      exit(abInternalError);
    end;

    for i := 0 to High(m) do begin
      xmpMsg := (m[i].Code = 'ZF-XMP') or (m[i].Code = 'ZF-XMP-PROFILE') or (m[i].Code = 'ZF-XMP-FILENAME') or
        (m[i].Code = 'ZF-AF');

      if xmpMsg then begin
        OutPdf := nil;
        AddMsg(Msgs, abError, 'EMBED-VERIFY', 'Self-check: ' + m[i].Text + ' (please report)');
        exit(abInternalError);
      end;
    end;

    result := abOK;
  except
    on e: Exception do begin
      OutPdf := nil;
      AddMsg(Msgs, abError, 'INTERNAL', 'Internal error: ' + e.Message);
      result := abInternalError;
    end;
  end;
end;

function WriteAllBytes(const FileName: string; const Data: TBytes; var Msgs: TAbMessages): Boolean;
var
  fs: TFileStream;
begin
  result := false;

  try
    fs := TFileStream.Create(FileName, fmCreate);

    try
      if Length(Data) > 0 then begin
        fs.WriteBuffer(Data[0], Length(Data));
      end;
    finally
      fs.Free;
    end;

    result := true;
  except
    on e: Exception do
      AddMsg(Msgs, abError, 'FILE', Format('The file "%s" cannot be written: %s', [FileName, e.Message]));
  end;
end;

class function TAbdecker.Embed(const PdfFile, XmlFile, OutFile: string;
  out Msgs: TAbMessages): TAbResult;
var
  pdf, xml, res: TBytes;
begin
  Msgs := nil;
  if not ReadAllBytes(PdfFile, pdf, Msgs) or not ReadAllBytes(XmlFile, xml, Msgs) then begin
    exit(abFileError);
  end;

  result := EmbedBytes(pdf, xml, res, Msgs);
  if (result = abOK) and not WriteAllBytes(OutFile, res, Msgs) then result := abFileError;
end;

class function TAbdecker.StripBytes(const Pdf: TBytes; out OutPdf: TBytes; out XmlName: string;
  out Msgs: TAbMessages): TAbResult;
var
  pi, vi: TEInvoiceInfo;
  m: TAbMessages;
  r: TAbResult;
  i: Integer;
begin
  OutPdf := nil;
  XmlName := '';
  Msgs := nil;

  try
    r := InfoFromBytes(Pdf, pi, m);

    if pi.Container = eicontXML then begin
      AddMsg(Msgs, abError, 'STRIP-NOT-PDF', 'The input is XML, not a PDF: there is nothing to remove');
      exit(abUnsupported);
    end;

    if (pi.Container <> eicontPDF) or (r in [abBrokenPDF, abEncrypted]) then begin
      Msgs := m;
      exit(r);
    end;

    if pi.InvoiceFileName = '' then begin
      Msgs := m;
      exit(abNoInvoice);
    end;

    for i := 0 to High(m) do begin
      if m[i].Code = 'PDF-XREF' then begin
        AddMsg(Msgs, abError, 'STRIP-BROKEN',
          'The PDF structure is broken, an update cannot be appended safely');
        exit(abBrokenPDF);
      end;
    end;

    r := StripInvoice(Pdf, pi.InvoiceFileName, OutPdf, Msgs);
    if r <> abOK then begin
      OutPdf := nil;
      exit(r);
    end;

    // read the result back: exactly one attachment less
    r := InfoFromBytes(OutPdf, vi, m);
    if not (r in [abOK, abNoInvoice]) or (Length(vi.Attachments) <> Length(pi.Attachments) - 1) then begin
      OutPdf := nil;
      AddMsg(Msgs, abError, 'STRIP-VERIFY', 'The generated PDF fails the self-check (please report)');
      exit(abInternalError);
    end;

    if r = abOK then begin
      AddMsg(Msgs, abWarning, 'STRIP-ANOTHER',
        Format('The PDF contains another invoice file (%s)', [vi.InvoiceFileName]));
    end;

    XmlName := pi.InvoiceFileName;
    result := abOK;
  except
    on e: Exception do begin
      OutPdf := nil;
      AddMsg(Msgs, abError, 'INTERNAL', 'Internal error: ' + e.Message);
      result := abInternalError;
    end;
  end;
end;

class function TAbdecker.Strip(const PdfFile, OutFile: string; out XmlName: string;
  out Msgs: TAbMessages): TAbResult;
var
  pdf, res: TBytes;
begin
  Msgs := nil;
  XmlName := '';
  if not ReadAllBytes(PdfFile, pdf, Msgs) then exit(abFileError);
  result := StripBytes(pdf, res, XmlName, Msgs);
  if (result = abOK) and not WriteAllBytes(OutFile, res, Msgs) then result := abFileError;
end;

class function TAbdecker.AttachBytes(const Xml: TBytes; const Docs: TEInvoiceDocuments;
  out OutXml: TBytes; out Msgs: TAbMessages): TAbResult;
var
  differs: Boolean;
  inv, back: TEInvoice;
  m: TAbMessages;
  r: TAbResult;
  d: TEInvoiceDocuments;
  i, j, n: Integer;
  ok: Boolean;
begin
  OutXml := nil;
  Msgs := nil;

  try
    r := LoadFromBytes(Xml, inv, m);

    if inv.Info.Container = eicontPDF then begin
      AddMsg(Msgs, abError, 'ATTACH-PDF', 'Files can only be attached to an invoice XML, not to a PDF ' +
        '(for a ZUGFeRD PDF: extract, attach, strip, embed)');
      exit(abUnsupported);
    end;

    if r <> abOK then begin
      Msgs := m;
      exit(r);
    end;

    if not (inv.Info.Syntax in [eisynCII, eisynUBLInvoice, eisynUBLCreditNote]) then begin
      AddMsg(Msgs, abError, 'ATTACH-SYNTAX', 'Only CII and UBL invoices can be changed, not ZUGFeRD 1.0');
      exit(abUnsupported);
    end;

    if (inv.Info.Syntax = eisynCII) and (inv.Info.Profile in [eiprofMinimum, eiprofBasicWL, eiprofBasic]) then begin
      AddMsg(Msgs, abError, 'ATTACH-PROFILE',
        Format('The profile %s has no attachments (BG-24)', [ProfileName(inv.Info.Profile)]));
      exit(abUnsupported);
    end;

    if (Length(Xml) >= 2) and (((Xml[0] = $FF) and (Xml[1] = $FE)) or ((Xml[0] = $FE) and (Xml[1] = $FF))) then begin
      AddMsg(Msgs, abError, 'ATTACH-UTF16', 'XML in UTF-16 is not supported');
      exit(abUnsupported);
    end;

    if Length(Docs) = 0 then begin
      AddMsg(Msgs, abError, 'ATTACH-NONE', 'No files to attach');
      exit(abUnsupported);
    end;

    // defaults and checks for every document
    ok := true;
    d := Copy(Docs, 0, Length(Docs));

    for i := 0 to High(d) do begin
      // the name only, without a path (either slash, on every platform)
      d[i].FileName := Trim(d[i].FileName);
      d[i].FileName := Copy(d[i].FileName, LastDelimiter('/\:', d[i].FileName) + 1, MaxInt);
      d[i].ID := Trim(d[i].ID);
      d[i].Description := Trim(d[i].Description);
      d[i].MimeType := Trim(d[i].MimeType);
      if d[i].ID = '' then d[i].ID := d[i].FileName;
      if d[i].MimeType = '' then d[i].MimeType := MimeForFileName(d[i].FileName);

      if d[i].FileName = '' then begin
        AddMsg(Msgs, abError, 'ATTACH-NAME', 'Every attachment needs a file name');
        ok := false;
        continue;
      end;

      if d[i].MimeType = '' then begin
        AddMsg(Msgs, abError, 'ATTACH-TYPE', Format('"%s": this file type is not allowed in e-invoices ' +
          '(allowed: %s)', [d[i].FileName, AllowedMimeList]));
        ok := false;
      end else if not AllowedMime(d[i].MimeType) then begin
        AddMsg(Msgs, abError, 'ATTACH-TYPE', Format('"%s": the MIME type %s is not allowed in e-invoices ' +
          '(allowed: %s)', [d[i].FileName, d[i].MimeType, AllowedMimeList]));
        ok := false;
      end;

      if Length(d[i].Content) = 0 then begin
        AddMsg(Msgs, abError, 'ATTACH-EMPTY', Format('"%s" is empty', [d[i].FileName]));
        ok := false;
      end;

      for j := 0 to High(inv.Documents) do begin
        if SameText(inv.Documents[j].ID, d[i].ID) or SameText(inv.Documents[j].FileName, d[i].FileName) then begin
          AddMsg(Msgs, abError, 'ATTACH-EXISTS',
            Format('The invoice already has an attachment "%s"', [d[i].FileName]));
          ok := false;
          break;
        end;
      end;

      for j := 0 to i - 1 do begin
        if SameText(d[j].ID, d[i].ID) or SameText(d[j].FileName, d[i].FileName) then begin
          AddMsg(Msgs, abError, 'ATTACH-EXISTS', Format('"%s" is given twice', [d[i].FileName]));
          ok := false;
          break;
        end;
      end;
    end;

    if not ok then exit(abUnsupported);

    r := InsertDocuments(Xml, inv.Info.Syntax, d, OutXml, Msgs);
    if r <> abOK then begin
      OutXml := nil;
      exit(r);
    end;

    OutXml := XmlMark(OutXml);

    // read the result back: the old documents plus exactly the new ones
    ok := (LoadFromBytes(OutXml, back, m) = abOK) and
      (Length(back.Documents) = Length(inv.Documents) + Length(d));
    n := Length(inv.Documents);

    if ok then begin
      for i := 0 to High(d) do begin
        differs := (back.Documents[n + i].ID <> d[i].ID) or (back.Documents[n + i].FileName <> d[i].FileName) or
          (back.Documents[n + i].MimeType <> d[i].MimeType) or
          (back.Documents[n + i].Description <> d[i].Description) or
          not SameBytes(back.Documents[n + i].Content, d[i].Content);
        if differs then ok := false;
      end;
    end;

    if not ok then begin
      OutXml := nil;
      AddMsg(Msgs, abError, 'ATTACH-VERIFY', 'The changed XML fails the self-check (please report)');
      exit(abInternalError);
    end;

    result := abOK;
  except
    on e: Exception do begin
      OutXml := nil;
      AddMsg(Msgs, abError, 'INTERNAL', 'Internal error: ' + e.Message);
      result := abInternalError;
    end;
  end;
end;

class function TAbdecker.Attach(const XmlFile: string; const Files: array of string;
  const OutFile: string; out Msgs: TAbMessages): TAbResult;
var
  xml, res: TBytes;
  d: TEInvoiceDocuments;
  i: Integer;
begin
  Msgs := nil;
  if not ReadAllBytes(XmlFile, xml, Msgs) then exit(abFileError);
  SetLength(d, Length(Files));

  for i := 0 to High(Files) do begin
    d[i] := Default(TEInvoiceDocument);
    d[i].FileName := Files[i];  // AttachBytes drops the path
    if not ReadAllBytes(Files[i], d[i].Content, Msgs) then exit(abFileError);
  end;

  result := AttachBytes(xml, d, res, Msgs);
  if (result = abOK) and not WriteAllBytes(OutFile, res, Msgs) then result := abFileError;
end;

{ First line in which two model dumps differ, '' if they are the same }
function ModelDiff(const a, b: TEInvoice): string;
var
  la, lb: TStringList;
  i: Integer;
begin
  result := '';
  la := TStringList.Create;
  lb := TStringList.Create;

  try
    DumpModel(a, false, false, la);
    DumpModel(b, false, false, lb);

    for i := 0 to la.Count - 1 do begin
      if (i >= lb.Count) or (la[i] <> lb[i]) then exit(la[i]);
    end;

    if lb.Count > la.Count then result := lb[la.Count];
  finally
    lb.Free;
    la.Free;
  end;
end;

class function TAbdecker.WriteCII(const Inv: TEInvoice; out Xml: TBytes;
  out Report: TAbCheckReport): TAbResult;
var
  data: TBytes;
  back: TEInvoice;
  m: TAbMessages;
  diff: string;
  i: Integer;
begin
  Xml := nil;
  Report := Default(TAbCheckReport);

  try
    data := XmlMark(CiiFromModel(Inv));

    // control characters are not allowed in XML 1.0 (CR is written as &#13;)
    for i := 0 to High(data) do begin
      if (data[i] < $20) and (data[i] <> $09) and (data[i] <> $0A) then begin
        AddMsg(Report.Messages, abError, 'CII-CHAR',
          'The invoice contains control characters, which XML does not allow');
        CountMessages(Report);
        exit(abUnsupported);
      end;
    end;

    // read back: the same model, else it is a bug of the writer
    result := LoadFromBytes(data, back, m);

    if result = abOK then begin
      diff := ModelDiff(Inv, back);
    end else begin
      diff := ResultText(result);
    end;

    if diff <> '' then begin
      AddMsg(Report.Messages, abError, 'CII-VERIFY',
        Format('The written CII fails the self-check (please report): %s', [diff]));
      CountMessages(Report);
      exit(abInternalError);
    end;

    // check what the receiver will read
    Check(back, Report);
    Report.Messages := Concat(m, Report.Messages);
    CountMessages(Report);
    Xml := data;
    result := abOK;
  except
    on e: Exception do begin
      Xml := nil;
      AddMsg(Report.Messages, abError, 'INTERNAL', 'Internal error: ' + e.Message);
      CountMessages(Report);
      result := abInternalError;
    end;
  end;
end;

class function TAbdecker.InvoiceFromJson(const Json: TBytes; const Options: TAbJsonOptions;
  out Inv: TEInvoice; out Msgs: TAbMessages): TAbResult;
begin
  Inv := Default(TEInvoice);
  Msgs := nil;

  try
    result := ReadInvoiceJson(Json, Options, Inv, Msgs);
  except
    on e: Exception do begin
      Inv := Default(TEInvoice);
      AddMsg(Msgs, abError, 'INTERNAL', 'Internal error: ' + e.Message);
      result := abInternalError;
    end;
  end;
end;

class function TAbdecker.VarsFromJson(const Json: TBytes; out Vars: TAbStrings;
  out Msgs: TAbMessages): TAbResult;
begin
  Vars := nil;
  Msgs := nil;

  try
    result := ReadVarsJson(Json, Vars, Msgs);
  except
    on e: Exception do begin
      Vars := nil;
      AddMsg(Msgs, abError, 'INTERNAL', 'Internal error: ' + e.Message);
      result := abInternalError;
    end;
  end;
end;

class function TAbdecker.ToHtml(const Inv: TEInvoice; const Lang: string;
  WithCheck: Boolean; PaymentOnly: Boolean): string;
var
  rep: TAbCheckReport;
begin
  rep := Default(TAbCheckReport);

  if WithCheck then begin
    Check(Inv, rep);
  end;

  result := InvoiceHtml(Inv, rep, WithCheck, Lang, PaymentOnly);
end;

class function TAbdecker.GiroCode(const Inv: TEInvoice): string;
begin
  result := PaymentInfo(Inv).Code;
end;

class function TAbdecker.QrCodeSvg(const Text: string): string;
var
  qr: TQrCode;
begin
  if QrEncode(Utf8Bytes(Text), qr) then begin
    result := QrSvg(qr);
  end else begin
    result := '';
  end;
end;

function TAbCheckReport.Failed(MinSeverity: TAbSeverity): Boolean;
begin
  case MinSeverity of
    abError: result := Errors > 0;
    abWarning: result := (Errors > 0) or (Warnings > 0);
  else
    result := Length(Messages) > 0;
  end;
end;

class function TAbdecker.InfoToJson(const FileName: string; r: TAbResult;
  const AInfo: TEInvoiceInfo; const Msgs: TAbMessages): string;
begin
  result := InfoJson(FileName, r, AInfo, Msgs);
end;

class function TAbdecker.CheckToJson(const FileName: string; r: TAbResult;
  const Inv: TEInvoice; const Report: TAbCheckReport; WithRules: Boolean): string;
begin
  result := CheckJson(FileName, r, Inv, Report, WithRules);
end;

class function TAbdecker.AttachmentsToJson(const FileName: string; r: TAbResult;
  const Files: TEInvoiceFiles; const Msgs: TAbMessages; WithContent: Boolean): string;
begin
  result := AttachmentsJson(FileName, r, Files, Msgs, WithContent);
end;

class function TAbdecker.InvoiceToJson(const FileName: string; r: TAbResult;
  const Inv: TEInvoice; const Msgs: TAbMessages): string;
begin
  result := InvoiceJson(FileName, r, Inv, Msgs);
end;

class function TAbdecker.Attachments(const FileName: string; out Files: TEInvoiceFiles;
  out Msgs: TAbMessages): TAbResult;
var
  data: TBytes;
  m: TAbMessages;
begin
  m := nil;
  Files := nil;

  if not ReadAllBytes(FileName, data, m) then begin
    Msgs := m;
    exit(abFileError);
  end;

  result := AttachmentsFromBytes(data, Files, Msgs);
end;

class function TAbdecker.AttachmentsFromBytes(const Data: TBytes; out Files: TEInvoiceFiles;
  out Msgs: TAbMessages): TAbResult;
begin
  Files := nil;
  Msgs := nil;

  try
    result := ReadAttachments(Data, Files, Msgs);
  except
    on e: Exception do begin
      AddMsg(Msgs, abError, 'INTERNAL', 'Internal error: ' + e.Message);
      result := abInternalError;
    end;
  end;
end;

class function TAbdecker.MessagesToJson(r: TAbResult; const Msgs: TAbMessages): string;
begin
  result := MessagesJson(ResultCodes[r], Msgs);
end;

class function TAbdecker.MessagesToJson(const AResult: string; const Msgs: TAbMessages): string;
begin
  result := MessagesJson(AResult, Msgs);
end;

class function TAbdecker.ResultCode(r: TAbResult): string;
begin
  result := ResultCodes[r];
end;

class function TAbdecker.SyntaxCode(s: TEInvoiceSyntax): string;
begin
  result := SyntaxCodes[s];
end;

class function TAbdecker.ProfileCode(p: TEInvoiceProfile): string;
begin
  result := ProfileCodes[p];
end;

class function TAbdecker.ContainerCode(c: TEInvoiceContainer): string;
begin
  result := ContainerCodes[c];
end;

class function TAbdecker.SeverityCode(s: TAbSeverity): string;
begin
  result := SeverityCodes[s];
end;

class function TAbdecker.OriginCode(o: TAbOrigin): string;
begin
  result := OriginCodes[o];
end;

class function TAbdecker.RuleStatusCode(s: TAbRuleStatus): string;
begin
  result := RuleStatusCodes[s];
end;

class function TAbdecker.ResultText(r: TAbResult): string;
begin
  case r of
    abOK: result := 'OK';
    abNoInvoice: result := 'No e-invoice found';
    abUnknownFormat: result := 'Unknown format';
    abFileError: result := 'File error';
    abBrokenPDF: result := 'Broken PDF';
    abBrokenXML: result := 'Broken XML';
    abEncrypted: result := 'PDF is encrypted';
    abUnsupported: result := 'Not supported';
    abInvalidData: result := 'Invalid invoice data';
  else
    result := 'Internal error';
  end;
end;

class function TAbdecker.SyntaxName(s: TEInvoiceSyntax): string;
begin
  case s of
    eisynCII: result := 'UN/CEFACT CII';
    eisynUBLInvoice: result := 'UBL Invoice';
    eisynUBLCreditNote: result := 'UBL CreditNote';
    eisynZUGFeRD1: result := 'ZUGFeRD 1.0';
  else
    result := 'unknown';
  end;
end;

class function TAbdecker.ProfileName(p: TEInvoiceProfile): string;
begin
  case p of
    eiprofMinimum: result := 'MINIMUM';
    eiprofBasicWL: result := 'BASIC WL';
    eiprofBasic: result := 'BASIC';
    eiprofComfort: result := 'COMFORT';
    eiprofEN16931: result := 'EN 16931';
    eiprofExtended: result := 'EXTENDED';
    eiprofXRechnung: result := 'XRECHNUNG';
    eiprofPeppol: result := 'Peppol BIS Billing';
  else
    result := 'unknown';
  end;
end;

class function TAbdecker.TypeCodeName(const Code: string): string;
begin
  if Code = '380' then result := 'Invoice'
  else if Code = '381' then result := 'Credit note'
  else if Code = '384' then result := 'Corrected invoice'
  else if Code = '389' then result := 'Self-billed invoice'
  else if Code = '326' then result := 'Partial invoice'
  else if Code = '386' then result := 'Prepayment invoice'
  else if Code = '875' then result := 'Partial construction invoice'
  else if Code = '876' then result := 'Partial final construction invoice'
  else if Code = '877' then result := 'Final construction invoice'
  else if Code = '751' then result := 'Invoice information'
  else result := '';
end;

{$IFDEF FPC}
initialization
  // string holds UTF-8 under FPC: conversions (literals, UnicodeString) must
  // use UTF-8, not the system code page. This acts on the whole program, as
  // LazUTF8 does in Lazarus programs (which therefore see no change). On
  // Unix, cwstring (above) does the conversions.
  SetMultiByteConversionCodePage(CP_UTF8);
  DefaultSystemCodePage := CP_UTF8;
{$ENDIF}
end.

