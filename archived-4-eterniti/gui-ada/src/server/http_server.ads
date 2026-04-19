-- ============================================================
--  HTTP_Server  —  Minimal HTTP/1.1 server for Ada GUI
--
--  Serves: HTML frontend on port 8340
--  API:    JSON REST endpoints for vault operations
--
--  Routes:
--    GET  /              → frontend/index.html
--    GET  /api/status    → vault status JSON
--    GET  /api/keys/:ex  → list keys for exchange
--    POST /api/keys/:ex  → add key
--    PUT  /api/keys/:ex/:slot → update key
--    DELETE /api/keys/:ex/:slot → delete key
--    POST /api/lock      → lock vault
--    POST /api/unlock    → unlock vault
-- ============================================================

pragma Ada_2022;

package HTTP_Server
   with SPARK_Mode => Off  -- Socket I/O not provable
is

   Default_Port : constant := 8340;

   -- Start the HTTP server (blocking)
   procedure Start (Port : Positive := Default_Port);

   -- Stop the server
   procedure Stop;

   -- Set the frontend directory path
   procedure Set_Frontend_Dir (Path : String);

end HTTP_Server;
