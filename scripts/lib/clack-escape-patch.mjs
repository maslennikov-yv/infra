/**
 * Escape в промптах @clack/core: где есть «Назад»/«Выход» в опциях select — выбирает их;
 * confirm — как «Нет»; text/password — отмена; multiselect — отмена (как Ctrl+C).
 */
import { Prompt } from "@clack/core";

const origOnKeypress = Prompt.prototype.onKeypress;

Prompt.prototype.onKeypress = function (ch, key) {
  if (key?.name !== "escape") {
    return origOnKeypress.call(this, ch, key);
  }

  if (typeof this.toggleAll === "function" || typeof this.isGroupSelected === "function") {
    this.state = "cancel";
  } else if (this._track) {
    this.state = "cancel";
  } else if (
    typeof this.value === "boolean" &&
    typeof this.cursor === "number" &&
    !Array.isArray(this.options)
  ) {
    this.value = false;
    this.state = "submit";
  } else if (Array.isArray(this.options)) {
    const back = this.options.find(
      (o) => o.value === "back" || o.value === "__back__",
    );
    const exitOpt = this.options.find((o) => o.value === "exit");
    const pick = back ?? exitOpt;
    if (pick) {
      this.value = pick.value;
      this.state = "submit";
    } else {
      this.state = "cancel";
    }
  } else {
    return origOnKeypress.call(this, ch, key);
  }

  this.emit("finalize");
  this.render();
  this.close();
};
