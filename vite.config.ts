import { paraglideVitePlugin } from '@inlang/paraglide-js';
import tailwindcss from '@tailwindcss/vite';
import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vite';

export default defineConfig({
	plugins: [
		paraglideVitePlugin({
			project: './project.inlang',
			outdir: './src/lib/paraglide',
			strategy: ['localStorage', 'baseLocale']
		}),
		tailwindcss(),
		sveltekit()
	],
	server: {
		watch: {
			// cargo writes and locks files inside src-tauri/target while building and
			// running the app; letting vite's file watcher descend into that directory
			// crashes it with `EBUSY` on windows. tauri watches src-tauri itself, so
			// nothing is lost by ignoring it here.
			ignored: ['**/src-tauri/**']
		}
	}
});
