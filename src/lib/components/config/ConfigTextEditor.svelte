<script lang="ts">
	import { m } from '$lib/paraglide/messages';
	import * as api from '$lib/api';
	import type { BaseConfigFile } from '$lib/types';
	import Button from '$lib/components/ui/Button.svelte';
	import { pushInfoToast } from '$lib/toast';

	type Props = {
		file: BaseConfigFile;
		locked: boolean;
	};

	let { file, locked }: Props = $props();

	let content = $state('');
	let savedContent = $state('');
	let loading = $state(true);
	let loadError = $state<string | null>(null);
	let saving = $state(false);

	const dirty = $derived(content !== savedContent);

	$effect(() => {
		// reload whenever a different file is selected
		const selectedFile = file;

		content = '';
		savedContent = '';
		loadError = null;
		loading = true;

		api.config
			.getText(selectedFile)
			.then((text) => {
				content = text;
				savedContent = text;
			})
			.catch((error) => {
				loadError = String(error);
			})
			.finally(() => {
				loading = false;
			});
	});

	async function save() {
		saving = true;
		try {
			await api.config.setText(file, content);
			savedContent = content;
			pushInfoToast({ message: m.configTextEditor_saved() });
		} finally {
			saving = false;
		}
	}

	function revert() {
		content = savedContent;
	}
</script>

{#if loadError}
	<div class="mt-2 text-red-500">
		{m.configTextEditor_loadError({ error: loadError })}
	</div>
{:else}
	<textarea
		bind:value={content}
		disabled={loading || locked}
		spellcheck="false"
		autocapitalize="off"
		autocomplete="off"
		class="text-primary-700 dark:bg-primary-900 dark:text-primary-300 focus:ring-accent-600 mt-3 h-[60vh] min-h-64 w-full resize-y rounded-lg border border-transparent px-3 py-2 font-mono text-sm focus:ring-2 focus:outline-hidden disabled:opacity-60"
	></textarea>

	<div class="mt-2 flex flex-wrap items-center gap-2">
		<Button
			color="accent"
			icon="mdi:content-save"
			disabled={!dirty || loading || locked}
			loading={saving}
			onclick={save}
		>
			{m.configTextEditor_save()}
		</Button>

		<Button color="primary" icon="mdi:undo" disabled={!dirty || locked} onclick={revert}>
			{m.configTextEditor_revert()}
		</Button>

		{#if dirty}
			<span class="text-primary-500 dark:text-primary-400 text-sm">
				{m.configTextEditor_unsaved()}
			</span>
		{/if}
	</div>
{/if}
