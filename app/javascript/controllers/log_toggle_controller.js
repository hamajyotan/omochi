import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["checkbox", "container"]

  connect() {
    this.toggle()
  }

  toggle() {
    if (this.hasContainerTarget && this.hasCheckboxTarget) {
      this.containerTarget.classList.toggle("chat-thread--show-logs", this.checkboxTarget.checked)
    }
  }
}
