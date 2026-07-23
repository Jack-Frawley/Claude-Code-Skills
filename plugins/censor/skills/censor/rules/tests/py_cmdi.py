# Test fixture for rule: py-command-injection  (NOT production code)

# ruleid: py-command-injection
os.system("rm -rf " + path)

# ruleid: py-command-injection
os.popen(cmd)

# ruleid: py-command-injection
subprocess.run(user_cmd, shell=True)

# ruleid: py-command-injection
subprocess.Popen(f"grep {pattern} file.txt", shell=True)

# ok: py-command-injection
os.system("ls -la")

# ok: py-command-injection
subprocess.run(["ls", "-la"], shell=False)

# ok: py-command-injection
subprocess.run(["grep", pattern, "file.txt"])

# ok: py-command-injection
subprocess.run("ls -la", shell=True)
