import * as api from '$lib/api';
import type { Prefs } from '$lib/types';

/**
 * Reactive, app-wide view of the user preferences stored by the backend.
 *
 * Components read {@link PrefsState.value} to react to preference changes, and
 * mutate it through `save()` so the frontend and backend stay in sync.
 */
class PrefsState {
	value: Prefs | null = $state(null);

	async refresh() {
		const newPrefs = await api.prefs.get();
		newPrefs.gamePrefs = new Map(Object.entries(newPrefs.gamePrefs));
		this.value = newPrefs;
	}

	/**
	 * Persists the current value. `mutate` is applied right before saving, so
	 * callers can update the value and save in one step.
	 */
	async save(mutate?: (prefs: Prefs) => void) {
		if (this.value === null) return;

		mutate?.(this.value);

		await api.prefs.set(this.value);
	}
}

const prefs = new PrefsState();

export default prefs;
