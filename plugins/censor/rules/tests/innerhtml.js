// Test fixture for rule: innerhtml-string-build  (NOT production code)

// ruleid: innerhtml-string-build
el.innerHTML = `<div class="row">${userInput}</div>`;

// ruleid: innerhtml-string-build
container.innerHTML = "<li>" + item.name + "</li>";

// ruleid: innerhtml-string-build
list.innerHTML += `<span>${label}</span>`;

// ok: innerhtml-string-build
el.textContent = userInput;

// ok: innerhtml-string-build
el.innerHTML = "<p>Static, no interpolation.</p>";
