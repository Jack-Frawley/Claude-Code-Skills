import java.io.*;
import javax.xml.parsers.*;

public class java_baseline {
  void deser(InputStream in) throws Exception {
    ObjectInputStream ois = new ObjectInputStream(in);
    // ruleid: java-native-deserialization
    Object o = ois.readObject();
    // ruleid: java-native-deserialization
    Object p = new ObjectInputStream(in).readObject();
  }

  void exec(String userInput) throws Exception {
    // ruleid: java-runtime-exec-concat
    Runtime.getRuntime().exec("ping " + userInput);
    // ok: java-runtime-exec-concat
    Runtime.getRuntime().exec(new String[]{"ping", userInput});
  }

  void query(javax.persistence.EntityManager em, String name) {
    // ruleid: java-query-concat
    em.createQuery("FROM User u WHERE u.name = '" + name + "'");
    // ok: java-query-concat
    em.createQuery("FROM User u WHERE u.name = :name").setParameter("name", name);
  }

  void spel(org.springframework.expression.ExpressionParser parser, String expr) {
    // ruleid: java-spel-injection
    parser.parseExpression(expr);
    // ok: java-spel-injection
    parser.parseExpression("#root.name");
  }

  void xml() throws Exception {
    // ruleid: java-xml-parser-xxe-review
    DocumentBuilderFactory dbf = DocumentBuilderFactory.newInstance();
    // ruleid: java-xml-parser-xxe-review
    SAXParserFactory spf = SAXParserFactory.newInstance();
  }
}
