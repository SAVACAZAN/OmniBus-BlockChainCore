-- ============================================================
--  Win32_Pipes  —  Thin Ada bindings to Windows Named Pipes
--
--  SPARK_Mode Off (FFI boundary)
--  Wraps: CallNamedPipeA from kernel32.dll
-- ============================================================

pragma Ada_2022;

with Interfaces.C;           use Interfaces.C;
with Interfaces.C.Strings;
with System;

package Win32_Pipes
   with SPARK_Mode => Off
is

   -- ── Handle type ───────────────────────────────────────────

   subtype HANDLE is System.Address;

   INVALID_HANDLE_VALUE : constant HANDLE :=
      System'To_Address (16#FFFFFFFFFFFFFFFF#);

   -- ── CallNamedPipeA ────────────────────────────────────────

   function CallNamedPipeA
      (lpNamedPipeName : Interfaces.C.Strings.chars_ptr;
       lpInBuffer      : System.Address;
       nInBufferSize   : Interfaces.C.unsigned_long;
       lpOutBuffer     : System.Address;
       nOutBufferSize  : Interfaces.C.unsigned_long;
       lpBytesRead     : access Interfaces.C.unsigned_long;
       nTimeOut        : Interfaces.C.unsigned_long) return Interfaces.C.int
      with Import, Convention => Stdcall,
           External_Name => "CallNamedPipeA";

   -- ── CreateFileA (for pipe client) ─────────────────────────

   GENERIC_READ       : constant := 16#80000000#;
   GENERIC_WRITE      : constant := 16#40000000#;
   OPEN_EXISTING      : constant := 3;
   FILE_ATTRIBUTE_NORMAL : constant := 16#80#;

   function CreateFileA
      (lpFileName            : Interfaces.C.Strings.chars_ptr;
       dwDesiredAccess       : Interfaces.C.unsigned_long;
       dwShareMode           : Interfaces.C.unsigned_long;
       lpSecurityAttributes  : System.Address;
       dwCreationDisposition : Interfaces.C.unsigned_long;
       dwFlagsAndAttributes  : Interfaces.C.unsigned_long;
       hTemplateFile         : HANDLE) return HANDLE
      with Import, Convention => Stdcall,
           External_Name => "CreateFileA";

   function CloseHandle (hObject : HANDLE) return Interfaces.C.int
      with Import, Convention => Stdcall,
           External_Name => "CloseHandle";

   function WriteFile
      (hFile                  : HANDLE;
       lpBuffer               : System.Address;
       nNumberOfBytesToWrite  : Interfaces.C.unsigned_long;
       lpNumberOfBytesWritten : access Interfaces.C.unsigned_long;
       lpOverlapped           : System.Address) return Interfaces.C.int
      with Import, Convention => Stdcall,
           External_Name => "WriteFile";

   function ReadFile
      (hFile                : HANDLE;
       lpBuffer             : System.Address;
       nNumberOfBytesToRead : Interfaces.C.unsigned_long;
       lpNumberOfBytesRead  : access Interfaces.C.unsigned_long;
       lpOverlapped         : System.Address) return Interfaces.C.int
      with Import, Convention => Stdcall,
           External_Name => "ReadFile";

   -- ── Pipe name constant ────────────────────────────────────

   Pipe_Name : constant String := "\\.\pipe\OmnibusVault" & ASCII.NUL;

   -- ── Timeout ───────────────────────────────────────────────

   Default_Pipe_Timeout_Ms : constant := 500;

end Win32_Pipes;
