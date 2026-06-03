import type MarkdownIt from 'markdown-it'
import type Token from 'markdown-it/lib/token'
import { defineConfig } from 'vitepress'
import { tabsMarkdownPlugin } from 'vitepress-plugin-tabs'
import { withMermaid } from 'vitepress-plugin-mermaid'

const BASE = '/Kaimon.jl/'
// In CI, KAIMON_ASSET_BASE points to GitHub Releases.
// Locally, falls back to VitePress public/assets/ served under the site base.
const ASSET_BASE = process.env.KAIMON_ASSET_BASE ?? (BASE + 'assets/')

// `themeConfig.logo` is run through VitePress's withBase(), which prepends BASE
// to a root-relative path. So locally it must be a BASE-relative path
// ('assets/...') — withBase adds BASE exactly once. In CI the absolute release
// URL (KAIMON_ASSET_BASE) passes through withBase unchanged. (The favicon below
// is a raw <head> href, not withBase'd, so it keeps the full ASSET_BASE path.)
const LOGO_SRC = process.env.KAIMON_ASSET_BASE
  ? process.env.KAIMON_ASSET_BASE + 'kaimon_logo1.png'
  : 'assets/kaimon_logo1.png'

// Rewrite ./assets/kaimon_*.gif to use ASSET_BASE via Vue's :src binding.
// Using :src makes it a runtime expression so VitePress doesn't try to
// resolve the path as an ESM import during SSR.
function kaimonAssetsPlugin(md: MarkdownIt, assetBase: string) {
  md.renderer.rules.image = function (
    tokens: Token[],
    idx: number,
    options: object,
    env: object,
    self: MarkdownIt['renderer'],
  ) {
    const token = tokens[idx]
    const srcIdx = token.attrIndex('src')
    if (srcIdx >= 0) {
      const src = token.attrs![srcIdx][1]
      const m = src.match(/(?:\.\.?\/)?assets\/(kaimon_[^"')]+\.gif)$/)
      if (m) {
        const alt = token.attrGet('alt') || ''
        return `<img :src="'${assetBase}${m[1]}'" alt="${alt}" />\n`
      }
    }
    return self.renderToken(tokens, idx, options)
  }
}

export default withMermaid(defineConfig({
  base: BASE,
  title: 'Kaimon.jl',
  description: 'Opening the gate between AI and Julia',
  lastUpdated: true,
  cleanUrls: true,
  head: [['link', { rel: 'icon', href: ASSET_BASE + 'kaimon_logo1.png' }]],

  vite: {
    define: {
      // Injected into Vue components (e.g. LogoBanner.vue)
      __ASSET_BASE__: JSON.stringify(ASSET_BASE),
    },
    vue: {
      template: {
        transformAssetUrls: {
          includeAbsolute: false,
        },
      },
    },
    build: {
      rollupOptions: {
        external: [/^\/assets\//, /^\/Kaimon\.jl\/assets\//],
      },
    },
  },

  markdown: {
    config(md) {
      md.use(tabsMarkdownPlugin)
      md.use((m: MarkdownIt) => kaimonAssetsPlugin(m, ASSET_BASE))
    },
  },

  mermaid: {},

  themeConfig: {
    logo: LOGO_SRC,
    nav: [
      { text: 'Guide', link: '/getting-started' },
      { text: 'Tools', link: '/tools' },
      { text: 'API', link: '/api' },
    ],

    sidebar: [
      {
        text: 'Introduction',
        items: [
          { text: 'Installation', link: '/installation' },
          { text: 'Getting Started', link: '/getting-started' },
          { text: 'Architecture', link: '/architecture' },
        ],
      },
      {
        text: 'Guide',
        items: [
          { text: 'Usage', link: '/usage' },
          { text: 'Tool Catalog', link: '/tools' },
          { text: 'The Gate', link: '/gate' },
          { text: 'Sessions', link: '/sessions' },
          { text: 'Extensions', link: '/extensions' },
          { text: 'Debugging', link: '/debugging' },
          { text: 'Semantic Search', link: '/search' },
          { text: 'Security', link: '/security' },
          { text: 'VS Code', link: '/vscode' },
          { text: 'Configuration', link: '/configuration' },
        ],
      },
      {
        text: 'Reference',
        items: [
          { text: 'API Reference', link: '/api' },
        ],
      },
    ],

    outline: {
      level: [2, 3],
    },

    search: {
      provider: 'local',
    },
    socialLinks: [
      { icon: 'github', link: 'https://github.com/kahliburke/Kaimon.jl' },
    ],
    footer: {
      message: 'Made with <a href="https://documenter.juliadocs.org/stable/">Documenter.jl</a> and <a href="https://vitepress.dev">VitePress</a>',
      copyright: 'Copyright © 2025-present',
    },
  },
}))
