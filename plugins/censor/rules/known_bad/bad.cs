using System.Runtime.Serialization.Formatters.Binary;
class Bad { void F(System.IO.Stream s){ var b = new BinaryFormatter(); b.Deserialize(s); } } // csharp-insecure-deserializer
