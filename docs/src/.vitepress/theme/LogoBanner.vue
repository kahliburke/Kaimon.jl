<script setup>
import { withBase } from 'vitepress'
</script>

<template>
  <div class="logo-banner">
    <img :src="withBase('/assets/kaimon-logo.jpg')" alt="Kaimon" class="logo-img" />
  </div>
</template>

<style scoped>
.logo-banner {
  display: flex;
  justify-content: center;
  padding: 3rem 0 0;
}
.logo-img {
  width: 320px;
  max-width: 70vw;
}
</style>
