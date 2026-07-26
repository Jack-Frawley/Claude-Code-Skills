// FP-corpus: clean Java. Nothing here should fire a rule.
// (Deliberately omits XML parser factories — java-xml-parser-xxe-review is an
//  advisory rule that fires on construction by design.)
public class clean {
  void q(java.sql.Connection c, String name) throws Exception {
    java.sql.PreparedStatement ps = c.prepareStatement("SELECT * FROM u WHERE name = ?");
    ps.setString(1, name);
  }
  void exec(String host) throws Exception {
    new ProcessBuilder("ping", "-c", "1", host).start();  // argv, not concat
  }
  void spel(org.springframework.expression.ExpressionParser p) {
    p.parseExpression("#root.name");  // constant expression
  }
}
