/* ============================================================
   Intern Daily Time Attendance — Azure SQL schema
   The API creates these automatically on first call; this file
   is here for reference or to run manually in the portal's
   Query editor.
   UpdatedAt is epoch milliseconds, stamped by the API. The app
   pulls "everything with UpdatedAt greater than my last sync",
   which is what keeps every device in step.
   ============================================================ */

IF OBJECT_ID('dbo.AppSettings','U') IS NULL
CREATE TABLE dbo.AppSettings(
  Id              int           NOT NULL CONSTRAINT PK_AppSettings PRIMARY KEY,
  Company         nvarchar(200) NULL,
  Program         nvarchar(200) NULL,
  Signatory       nvarchar(200) NULL,
  SignatoryTitle  nvarchar(200) NULL,
  DefaultRequired int           NOT NULL CONSTRAINT DF_AppSettings_Req DEFAULT 300,
  UpdatedAt       bigint        NOT NULL CONSTRAINT DF_AppSettings_Upd DEFAULT 0
);

IF OBJECT_ID('dbo.Interns','U') IS NULL
CREATE TABLE dbo.Interns(
  Id            nvarchar(40)  NOT NULL CONSTRAINT PK_Interns PRIMARY KEY,
  UserId        nvarchar(80)  NOT NULL,
  Pass          nvarchar(200) NULL,
  Role          nvarchar(20)  NOT NULL CONSTRAINT DF_Interns_Role DEFAULT 'intern',
  Name          nvarchar(160) NULL,
  RoleText      nvarchar(200) NULL,
  Company       nvarchar(200) NULL,
  RequiredHours decimal(9,2)  NULL,
  AdjustHours   decimal(9,2)  NOT NULL CONSTRAINT DF_Interns_Adj DEFAULT 0,
  Active        bit           NOT NULL CONSTRAINT DF_Interns_Active DEFAULT 1,
  Deleted       bit           NOT NULL CONSTRAINT DF_Interns_Del DEFAULT 0,
  UpdatedAt     bigint        NOT NULL CONSTRAINT DF_Interns_Upd DEFAULT 0
);

IF OBJECT_ID('dbo.TimeLogs','U') IS NULL
CREATE TABLE dbo.TimeLogs(
  InternId   nvarchar(40) NOT NULL,
  LogDate    char(10)     NOT NULL,          -- YYYY-MM-DD
  SignIn     char(5)      NULL,              -- HH:MM
  BreakStart char(5)      NULL,
  BreakEnd   char(5)      NULL,
  SignOut    char(5)      NULL,
  OtIn       char(5)      NULL,
  OtOut      char(5)      NULL,
  Deleted    bit          NOT NULL CONSTRAINT DF_TimeLogs_Del DEFAULT 0,
  UpdatedAt  bigint       NOT NULL CONSTRAINT DF_TimeLogs_Upd DEFAULT 0,
  CONSTRAINT PK_TimeLogs PRIMARY KEY (InternId, LogDate)
);

IF OBJECT_ID('dbo.SignInEvents','U') IS NULL
CREATE TABLE dbo.SignInEvents(
  InternId  nvarchar(40)  NOT NULL,
  AtUtc     nvarchar(40)  NOT NULL,          -- ISO timestamp from the device
  Lat       float         NULL,
  Lng       float         NULL,
  Accuracy  int           NULL,
  ErrText   nvarchar(200) NULL,
  Deleted   bit           NOT NULL CONSTRAINT DF_SignIns_Del DEFAULT 0,
  UpdatedAt bigint        NOT NULL CONSTRAINT DF_SignIns_Upd DEFAULT 0,
  CONSTRAINT PK_SignInEvents PRIMARY KEY (InternId, AtUtc)
);

IF OBJECT_ID('dbo.Completions','U') IS NULL
CREATE TABLE dbo.Completions(
  InternId    nvarchar(40) NOT NULL CONSTRAINT PK_Completions PRIMARY KEY,
  DoneDate    char(10)     NULL,
  TotalMinutes int         NULL,
  Seen        bit          NOT NULL CONSTRAINT DF_Completions_Seen DEFAULT 0,
  Deleted     bit          NOT NULL CONSTRAINT DF_Completions_Del DEFAULT 0,
  UpdatedAt   bigint       NOT NULL CONSTRAINT DF_Completions_Upd DEFAULT 0
);

/* ---- columns added after the first release ---- */
IF COL_LENGTH('dbo.AppSettings','CertBg') IS NULL
  ALTER TABLE dbo.AppSettings ADD CertBg nvarchar(max) NULL;
IF COL_LENGTH('dbo.Completions','CertCode') IS NULL
  ALTER TABLE dbo.Completions ADD CertCode nvarchar(40) NULL;
IF COL_LENGTH('dbo.TimeLogs','Ips') IS NULL
  ALTER TABLE dbo.TimeLogs ADD Ips nvarchar(400) NULL;      -- {"in":"1.2.3.4","bs":"…"}
IF COL_LENGTH('dbo.SignInEvents','Ip') IS NULL
  ALTER TABLE dbo.SignInEvents ADD Ip nvarchar(60) NULL;

IF COL_LENGTH('dbo.AppSettings','Branch') IS NULL
  ALTER TABLE dbo.AppSettings ADD Branch nvarchar(200) NULL;
IF COL_LENGTH('dbo.AppSettings','SiteUrl') IS NULL
  ALTER TABLE dbo.AppSettings ADD SiteUrl nvarchar(300) NULL;
IF COL_LENGTH('dbo.AppSettings','Msg1') IS NULL
  ALTER TABLE dbo.AppSettings ADD Msg1 nvarchar(300) NULL;
IF COL_LENGTH('dbo.AppSettings','Msg2') IS NULL
  ALTER TABLE dbo.AppSettings ADD Msg2 nvarchar(300) NULL;
IF COL_LENGTH('dbo.AppSettings','LogoLeft') IS NULL
  ALTER TABLE dbo.AppSettings ADD LogoLeft nvarchar(max) NULL;
IF COL_LENGTH('dbo.AppSettings','LogoRight') IS NULL
  ALTER TABLE dbo.AppSettings ADD LogoRight nvarchar(max) NULL;

IF COL_LENGTH('dbo.Completions','ShortUrl') IS NULL
  ALTER TABLE dbo.Completions ADD ShortUrl nvarchar(200) NULL;
IF COL_LENGTH('dbo.Completions','QrOn') IS NULL
  ALTER TABLE dbo.Completions ADD QrOn bit NULL;

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Completions_CertCode')
  CREATE INDEX IX_Completions_CertCode ON dbo.Completions(CertCode);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Interns_UpdatedAt')
  CREATE INDEX IX_Interns_UpdatedAt ON dbo.Interns(UpdatedAt);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_TimeLogs_UpdatedAt')
  CREATE INDEX IX_TimeLogs_UpdatedAt ON dbo.TimeLogs(UpdatedAt);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_SignInEvents_UpdatedAt')
  CREATE INDEX IX_SignInEvents_UpdatedAt ON dbo.SignInEvents(UpdatedAt);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Completions_UpdatedAt')
  CREATE INDEX IX_Completions_UpdatedAt ON dbo.Completions(UpdatedAt);
