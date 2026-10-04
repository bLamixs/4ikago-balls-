const form = document.getElementById("note-form");
const textInput = document.getElementById("note-text");
const notesList = document.getElementById("notes-list");
const message = document.getElementById("message");
const loading = document.getElementById("loading");

function showMessage(text, isError = false) {
  message.textContent = text;
  message.className = isError ? "message error" : "message success";
}

function formatDate(dateString) {
  return new Date(dateString).toLocaleString("ru-RU");
}

function renderNotes(notes) {
  notesList.innerHTML = "";

  if (notes.length === 0) {
    const item = document.createElement("li");
    item.className = "empty-note";
    item.textContent = "Заметок пока нет.";
    notesList.appendChild(item);
    return;
  }

  for (const note of notes) {
    const item = document.createElement("li");
    item.className = "note-item";

    const text = document.createElement("div");
    text.className = "note-text";
    text.textContent = note.text;

    const date = document.createElement("time");
    date.className = "note-date";
    date.dateTime = note.created_at;
    date.textContent = formatDate(note.created_at);

    item.append(text, date);
    notesList.appendChild(item);
  }
}

async function loadNotes() {
  loading.hidden = false;
  loading.textContent = "Загрузка заметок...";

  try {
    // Относительный путь: фронтенд и API обслуживаются одним Flask-сервером.
    const response = await fetch("/api/notes");

    if (!response.ok) {
      throw new Error("Сервер вернул ошибку");
    }

    const notes = await response.json();
    renderNotes(notes);
  } catch (error) {
    notesList.innerHTML = "";
    showMessage("Не удалось загрузить заметки. Проверьте Flask и PostgreSQL.", true);
  } finally {
    loading.hidden = true;
  }
}

form.addEventListener("submit", async (event) => {
  event.preventDefault();

  const text = textInput.value.trim();

  if (!text) {
    showMessage("Введите текст заметки.", true);
    return;
  }

  showMessage("Сохранение...");

  try {
    const response = await fetch("/api/notes", {
      method: "POST",
      headers: {
        "Content-Type": "application/json"
      },
      body: JSON.stringify({ text })
    });

    const result = await response.json();

    if (!response.ok) {
      throw new Error(result.error || "Не удалось сохранить заметку");
    }

    textInput.value = "";
    showMessage("Заметка сохранена.");
    await loadNotes();
  } catch (error) {
    showMessage(error.message, true);
  }
});

loadNotes();