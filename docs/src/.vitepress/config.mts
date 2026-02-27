import type MarkdownIt from 'markdown-it'
import type Token from 'markdown-it/lib/token'
import { defineConfig } from 'vitepress'
import { tabsMarkdownPlugin } from 'vitepress-plugin-tabs'
import { withMermaid } from 'vitepress-plugin-mermaid'

const BASE = '/Kaimon.jl/'
// In CI, KAIMON_ASSET_BASE points to GitHub Releases.
// Locally, falls back to VitePress public/assets/ served under the site base.
const ASSET_BASE = process.env.KAIMON_ASSET_BASE ?? (BASE + 'assets/')

// Rewrite ./assets/kaimon_*.gif src attributes to use ASSET_BASE so that
// local dev builds serve from public/assets/ and CI builds serve from
// the docs-assets GitHub release.
function kaimonAssetsPlugin(md: MarkdownIt, assetBase: string) {
  const defaultRender = md.renderer.rules.image
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
        token.attrs![srcIdx][1] = assetBase + m[1]
      }
    }
    return defaultRender
      ? defaultRender(tokens, idx, options, env, self)
      : self.renderToken(tokens, idx, options)
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
  },

  markdown: {
    config(md) {
      md.use(tabsMarkdownPlugin)
      md.use((m: MarkdownIt) => kaimonAssetsPlugin(m, ASSET_BASE))
    },
  },

  mermaid: {},

  themeConfig: {
    logo: ASSET_BASE + 'kaimon_logo1.png',
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
