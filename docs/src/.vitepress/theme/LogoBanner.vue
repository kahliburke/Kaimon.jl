<script setup lang="ts">
declare const __ASSET_BASE__: string
const logoSrc = __ASSET_BASE__ + 'kaimon-logo.jpg'
</script>

<template>
  <div class="logo-banner">
    <img :src="logoSrc" alt="Kaimon" class="logo-img" />
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
