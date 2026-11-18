import react from '@vitejs/plugin-react';
import tailwindcss from '@tailwindcss/vite';
import { defineConfig } from 'vite';

export default defineConfig({
  root: 'remote-ui',
  base: '/remote/',
  plugins: [react(), tailwindcss()],
  build: {
    outDir: '../android/app/src/main/assets/remote',
    emptyOutDir: true,
  },
});
