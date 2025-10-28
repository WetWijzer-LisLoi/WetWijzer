/**
 * Tailwind CSS Configuration
 * 
 * This file configures the Tailwind CSS framework for the WetWijzer application.
 * It defines the color palette, typography, spacing, and other design tokens
 * that will be used throughout the application.
 * 
 * @module tailwind.config
 * @type {import('tailwindcss').Config}
 * @see https://tailwindcss.com/docs/configuration
 */
const path = require('path');
module.exports = {
  /**
   * Dark mode configuration
   * @type {'media'|'class'|false}
   * @default 'media'
   * @description Use 'class' strategy for dark mode to enable programmatic control
   * @see https://tailwindcss.com/docs/dark-mode
   */
  darkMode: 'class',
  /**
   * Content configuration
   * @type {string[]}
   * @description Paths to all template files that might contain Tailwind class names
   * This helps with purging unused styles in production
   * @see https://tailwindcss.com/docs/content-configuration
   */
  content: [
    // NOTE: this config file lives in app/javascript/config
    // Use absolute paths to avoid accidental node_modules matches on Windows
    // Rails views (ERB templates)
    path.resolve(__dirname, '../../views/**/*.html.erb'),
    path.resolve(__dirname, '../../views/**/*.erb'),
    // Ruby helpers and ViewComponents that render classes
    path.resolve(__dirname, '../../helpers/**/*.rb'),
    path.resolve(__dirname, '../../components/**/*.{rb,erb}'),
    // Asset pipeline styles that may contain @apply or theme() usages
    path.resolve(__dirname, '../../assets/stylesheets/**/*.{css,scss}'),
    // Only Vite application JS under app/javascript (avoid node_modules)
    path.resolve(__dirname, '../**/*.js')
  ],
  /**
   * Plugins
   * @type {import('tailwindcss').PluginCreator[]}
   * @description Official and custom Tailwind CSS plugins
   * @see https://tailwindcss.com/docs/plugins
   */
  plugins: [
    // Official forms plugin for better form styling
    // @see https://github.com/tailwindlabs/tailwindcss-forms
    require('@tailwindcss/forms'),
    // Custom theme variants for theme-specific styling
    function({ addVariant }) {
      // Professional themes
      addVariant('theme-slate', '.theme-slate &');
      addVariant('theme-indigo', '.theme-indigo &');
      addVariant('theme-sky', '.theme-sky &');
      addVariant('theme-teal', '.theme-teal &');
      addVariant('theme-cyan', '.theme-cyan &');
      addVariant('theme-green', '.theme-green &');
      addVariant('theme-purple', '.theme-purple &');
      addVariant('theme-red', '.theme-red &');
      // Vibrant/fun themes
      addVariant('theme-original', '.theme-original &');
      addVariant('theme-blue', '.theme-blue &');
      addVariant('theme-rose', '.theme-rose &');
      addVariant('theme-amber', '.theme-amber &');
      addVariant('theme-emerald', '.theme-emerald &');
      addVariant('theme-violet', '.theme-violet &');
      addVariant('theme-fuchsia', '.theme-fuchsia &');
      addVariant('theme-pink', '.theme-pink &');
    }
  ],
  /**
   * Theme customization
   * @type {import('tailwindcss').Config['theme']}
   * @description Extend or override the default Tailwind theme
   * @see https://tailwindcss.com/docs/theme
   */
  theme: {
    extend: {
      /**
       * Custom color palette
       * @type {Record<string, string>}
       * @description Custom colors that extend Tailwind's default color palette
       */
      colors: {
        // Dark blue used for backgrounds and primary elements
        midnight: '#0f172a',
        // Lighter blue used for secondary elements
        navy: '#1e293b',
        // Light gray used for borders and subtle backgrounds
        mist: '#cbd5e1',
        // Bright blue used for interactive elements and highlights
        sky: '#38bdf8',
      },
      
      /**
       * Custom box shadows
       * @type {Record<string, string>}
       * @description Custom shadow styles that extend Tailwind's defaults
       */
      boxShadow: {
        // Custom blue outline shadow for focus states
        'outline-blue': '0 0 0 3px rgba(191, 219, 254, 0.5)',
      }
    }
  }
}
