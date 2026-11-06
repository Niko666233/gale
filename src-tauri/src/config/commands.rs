use std::{fs, path::Path};

use eyre::{Context, eyre};
use tauri::{AppHandle, command};

use super::{AnyFileKind, frontend};
use crate::{state::ManagerExt, util::{cmd::Result, error::IoResultExt}};

#[command]
pub fn get_config_files(app: AppHandle) -> Result<Vec<frontend::File>> {
    let mut manager = app.lock_manager();
    let profile = manager.active_profile_mut();

    profile.refresh_config();

    Ok(profile.config_cache.to_frontend())
}

#[command]
pub fn set_config_entry(
    file: &Path,
    section: &str,
    entry: &str,
    value: frontend::Value,
    app: AppHandle,
) -> Result<()> {
    let mut manager = app.lock_manager();

    let profile = manager.active_profile_mut();
    let file = profile.config_cache.find_file(file)?;

    match &mut file.kind {
        AnyFileKind::BepInEx(file) => file.find_entry(section, entry)?.set(value),
        AnyFileKind::GDWeave(file) => file.set(entry, value),
        _ => return Err(eyre!("unsupported for this format").into()),
    }?;

    file.write(&profile.path).context("failed to write file")?;
    Ok(())
}

#[command]
pub fn reset_config_entry(
    file: &Path,
    section: &str,
    entry: &str,
    app: AppHandle,
) -> Result<frontend::Value> {
    let mut manager = app.lock_manager();

    let profile = manager.active_profile_mut();
    let file = profile.config_cache.find_file(file)?;

    let value = match &mut file.kind {
        AnyFileKind::BepInEx(file) => file.find_entry(section, entry)?.reset(),
        _ => return Err(eyre!("unsupported for this format").into()),
    }?;

    file.write(&profile.path).context("failed to write file")?;
    Ok(value)
}

#[command]
pub fn reset_config_file(file: &Path, app: AppHandle) -> Result<()> {
    let mut manager = app.lock_manager();

    let profile = manager.active_profile_mut();
    let file = profile.config_cache.find_file(file)?;

    match &mut file.kind {
        AnyFileKind::BepInEx(file) => file.reset_all()?,
        _ => return Err(eyre!("unsupported for this format").into()),
    }

    file.write(&profile.path).context("failed to write file")?;
    Ok(())
}

/// Reads a config file that the structured editor cannot handle (or failed to
/// parse) so it can be edited as plain text.
#[command]
pub fn get_config_text(file: &Path, app: AppHandle) -> Result<String> {
    let manager = app.lock_manager();
    let profile = manager.active_profile();

    if !profile.config_cache.contains_file(file) {
        return Err(eyre!("file is not a known config file").into());
    }

    let path = profile.path.join(file);
    let text = fs::read_to_string(&path).fs_context("reading config file", &path)?;

    Ok(text)
}

/// Writes a plain text config file back to disk.
#[command]
pub fn set_config_text(file: &Path, content: String, app: AppHandle) -> Result<()> {
    let mut manager = app.lock_manager();
    let profile = manager.active_profile_mut();

    if !profile.config_cache.contains_file(file) {
        return Err(eyre!("file is not a known config file").into());
    }

    let path = profile.path.join(file);

    // the webview hands us "\n" line breaks, so restore the file's own convention
    let uses_crlf = fs::read_to_string(&path).is_ok_and(|text| text.contains("\r\n"));
    let content = if uses_crlf {
        content.replace('\r', "").replace('\n', "\r\n")
    } else {
        content
    };

    fs::write(&path, content).fs_context("writing config file", &path)?;

    // the modified time changed, so the next refresh re-reads it
    Ok(())
}

#[command]
pub fn open_config_file(file: &Path, app: AppHandle) -> Result<()> {
    let manager = app.lock_manager();

    let profile = manager.active_profile();
    let path = profile.path.join(file);
    open::that_detached(&path)
        .with_context(|| format!("failed to open config file at {}", path.display()))?;

    Ok(())
}

#[command]
pub fn delete_config_file(file: &Path, app: AppHandle) -> Result<()> {
    let mut manager = app.lock_manager();

    let profile = manager.active_profile_mut();

    let Some(index) = profile
        .config_cache
        .0
        .iter()
        .position(|f| f.relative_path == file)
    else {
        return Ok(()); // ignore if the file is not in the list
    };

    profile.config_cache.0.remove(index);

    let path = profile.path.join(file);
    trash::delete(path).context("failed to move file to recycle bin")?;

    Ok(())
}
