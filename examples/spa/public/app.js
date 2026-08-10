const list = document.getElementById("tasks");

fetch("/api/tasks")
  .then((response) => response.json())
  .then((tasks) => {
    list.innerHTML = "";
    for (const task of tasks) {
      const item = document.createElement("li");
      item.textContent = task.title;
      if (task.done) item.classList.add("done");
      list.append(item);
    }
  })
  .catch((error) => {
    list.innerHTML = `<li class="error">${error}</li>`;
  });
