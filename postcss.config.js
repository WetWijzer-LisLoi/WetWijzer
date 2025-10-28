// PostCSS config — Tailwind CSS v4 via @tailwindcss/postcss
// This runs AFTER Sass, so @apply directives in .scss files are resolved.
module.exports = {
  plugins: {
    '@tailwindcss/postcss': {}
  }
}
