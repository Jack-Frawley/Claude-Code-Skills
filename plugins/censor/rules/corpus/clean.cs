// FP-corpus: clean C#. Nothing here should fire a rule.
using System.Data.SqlClient;
public class Clean {
  void Sql(string name) {
    var cmd = new SqlCommand("SELECT * FROM T WHERE Name = @n");   // literal + param
    cmd.Parameters.AddWithValue("@n", name);
  }
  object Render(string s) { return System.Web.HttpUtility.HtmlEncode(s); } // encoded, not Html.Raw
  void Json() {
    var settings = new Newtonsoft.Json.JsonSerializerSettings {
      TypeNameHandling = Newtonsoft.Json.TypeNameHandling.None };        // safe
  }
}
