import { h } from 'vue'
import type { Theme } from 'vitepress'
import DefaultTheme from 'vitepress/theme'
import LogoBanner from './LogoBanner.vue'
import './style.css'
import './docstrings.css'

export default {
  extends: DefaultTheme,
  Layout() {
    return h(DefaultTheme.Layout, null, {
      'home-hero-before': () => h(LogoBanner),
    })
  },
} satisfies Theme
