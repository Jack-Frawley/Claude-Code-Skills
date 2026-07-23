# Test fixture for rule: py-unsafe-deserialization  (NOT production code)

# ruleid: py-unsafe-deserialization
obj = pickle.loads(data)

# ruleid: py-unsafe-deserialization
obj = pickle.load(open("state.pkl", "rb"))

# ruleid: py-unsafe-deserialization
config = yaml.load(raw)

# ruleid: py-unsafe-deserialization
code = marshal.loads(blob)

# ok: py-unsafe-deserialization
config = yaml.safe_load(raw)

# ok: py-unsafe-deserialization
config = yaml.load(raw, Loader=yaml.SafeLoader)

# ok: py-unsafe-deserialization
obj = json.loads(data)
