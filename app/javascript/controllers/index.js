/**
 * Stimulus Controllers Entry Point
 * 
 * This file serves as the main entry point for all Stimulus controllers in the application.
 * It initializes the Stimulus application and automatically registers all controllers
 * found in the controllers directory and its subdirectories.
 * 
 * @module controllers/index
 * @see https://stimulus.hotwired.dev/handbook/installing#using-other-build-systems
 */

import { Application } from "@hotwired/stimulus";
import { registerControllers } from "stimulus-vite-helpers";

// Initialize the Stimulus application
const application = Application.start();

// Expose Stimulus on window so tests (and debugging) can detect it
// This is safe and useful in development/test; in production it has negligible impact
if (typeof window !== 'undefined' && import.meta.env.MODE !== 'production') {
  window.Stimulus = application;
}

// Automatically import all controllers in the controllers directory
// This uses Vite's import.meta.glob to find all files matching the pattern
const controllers = import.meta.glob(
  "./**/*_controller.js", 
  { eager: true }
);

// Register all controllers with the Stimulus application
// This makes them available for use in the HTML with data-controller attributes
registerControllers(application, controllers);

// Register additional third-party Stimulus controllers
import AutoSubmit from '@stimulus-components/auto-submit';

// Register the auto-submit controller which automatically submits forms when their inputs change
// @see https://www.stimulus-components.com/docs/stimulus-auto-submit/
application.register('auto-submit', AutoSubmit);

// Export the application instance for programmatic access if needed
export { application };