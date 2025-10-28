// Stimulus Controllers Entry Point
// Auto-registers all *_controller.js files via Vite glob import.

import { Application } from "@hotwired/stimulus";
import { registerControllers } from "stimulus-vite-helpers";

const application = Application.start();

// Expose Stimulus on window for tests/debugging (non-production only)
if (typeof window !== 'undefined' && import.meta.env.MODE !== 'production') {
  window.Stimulus = application;
}

// Auto-import and register all controllers in this directory tree
const controllers = import.meta.glob(
  "./**/*_controller.js", 
  { eager: true }
);
registerControllers(application, controllers);

// Third-party Stimulus controllers
import AutoSubmit from '@stimulus-components/auto-submit';
application.register('auto-submit', AutoSubmit);

export { application };