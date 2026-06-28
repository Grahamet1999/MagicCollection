/// Connection settings for the local Microsoft SQL Server instance.
///
/// Adjust these to match your environment if needed. Defaults target a default
/// local instance (MSSQLSERVER) using Windows authentication.
class DbConfig {
  /// Server / instance. Use `localhost` for a default instance, or
  /// `localhost\\SQLEXPRESS` (escaped) for a named instance.
  static const String server = 'localhost';

  /// Database the app stores its data in. Created automatically if missing.
  static const String database = 'MtgCollection';

  /// Installed ODBC driver name. Both 17 and 18 are present on this machine;
  /// 18 encrypts by default, so we trust the local self-signed certificate.
  static const String driver = 'ODBC Driver 18 for SQL Server';

  /// Builds a Windows-authentication ODBC connection string for [db].
  static String connectionString(String db) =>
      'DRIVER={$driver};'
      'SERVER=$server;'
      'DATABASE=$db;'
      'Trusted_Connection=yes;'
      'Encrypt=yes;'
      'TrustServerCertificate=yes;';
}
