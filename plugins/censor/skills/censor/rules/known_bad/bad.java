import java.io.*;
class Bad { void f(InputStream in) throws Exception {
  Object o = new ObjectInputStream(in).readObject();   // java-native-deserialization
}}
