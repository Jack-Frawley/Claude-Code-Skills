# Test fixture for rule: py-jinja-autoescape-off  (NOT production code)

# ruleid: py-jinja-autoescape-off
env = jinja2.Environment(loader=loader, autoescape=False)

# ruleid: py-jinja-autoescape-off
env = Environment(autoescape=False)

# ok: py-jinja-autoescape-off
env = jinja2.Environment(loader=loader, autoescape=True)

# ok: py-jinja-autoescape-off
env = jinja2.Environment(loader=loader, autoescape=select_autoescape(["html", "xml"]))
