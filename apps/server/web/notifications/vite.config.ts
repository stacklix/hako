import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  base: '/admin/notifications-ui/',
  build: { outDir: 'dist/web' },
});
