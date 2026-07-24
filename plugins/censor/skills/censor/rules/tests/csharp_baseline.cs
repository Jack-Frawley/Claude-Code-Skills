using System;
using System.Data.SqlClient;
using System.Runtime.Serialization.Formatters.Binary;
using System.Diagnostics;
using System.Xml;

public class CsharpBaseline {
  void Deser(System.IO.Stream s) {
    // ruleid: csharp-insecure-deserializer
    var bf = new BinaryFormatter();
    var o = bf.Deserialize(s);
  }

  void Sql(Microsoft.EntityFrameworkCore.DbSet<object> set, string name) {
    // ruleid: csharp-sql-raw
    set.FromSqlRaw($"SELECT * FROM Users WHERE Name = '{name}'");
    // ok: csharp-sql-raw
    set.FromSqlRaw("SELECT * FROM Users WHERE Name = {0}", name);
    // ruleid: csharp-sql-raw
    var cmd = new SqlCommand($"SELECT * FROM T WHERE id={name}");
    // ok: csharp-sql-raw
    var cmd2 = new SqlCommand("SELECT * FROM T WHERE id=@id");
  }

  object Raw(string name) {
    // ruleid: csharp-html-raw
    return Html.Raw(name);
  }
  object RawOk() {
    // ok: csharp-html-raw
    return Html.Raw("<b>static</b>");
  }

  void Json() {
    // ruleid: csharp-json-typenamehandling
    var s = new Newtonsoft.Json.JsonSerializerSettings { TypeNameHandling = TypeNameHandling.All };
  }

  void Proc(string userInput) {
    // ruleid: csharp-process-start-concat
    Process.Start("cmd /c " + userInput);
  }

  void Xml() {
    var settings = new XmlReaderSettings();
    // ruleid: csharp-xxe-dtd-parse
    settings.DtdProcessing = DtdProcessing.Parse;
  }
}
