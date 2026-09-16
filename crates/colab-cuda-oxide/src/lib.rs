//! Load cuda-oxide kernels that were compiled inside an evcxr `%%rust` cell.
//!
//! cuda-oxide embeds the PTX of a `#[cuda_module]` into the binary that the
//! module was compiled into, and the generated `kernels::load(&ctx)` finds
//! that binary with `std::env::current_exe()`. Under evcxr every cell is a
//! separate shared object loaded into one long-lived runtime process, so
//! `current_exe()` names the runtime, not the cell, and `load()` reports
//! that the module was not found.
//!
//! This crate reads the bundle from the shared object that contains a given
//! function instead. That function has to be defined in the cell itself,
//! which is what [`load_kernels!`] arranges; the plain functions are for
//! callers that want to supply the anchor and bundle name by hand.
//!
//! Scope: the PTX payload of a non-generic module, which is what the
//! verified route on Colab T4 uses. Cubin, NVVM IR, LTOIR and merged
//! generic bundles go through cuda-host's own loaders once those learn to
//! read from a path.

use std::ffi::{CStr, OsStr};
use std::os::unix::ffi::OsStrExt;
use std::path::PathBuf;
use std::sync::Arc;

use cuda_core::embedded::{ArtifactPayloadKind, artifact_bundles_from_binary_path};
use cuda_core::{CudaContext, DriverError, EmbeddedModuleError};
/// Re-exported so [`load_kernels!`] can name it from any cell.
pub use cuda_core::CudaModule;

/// A function defined in the cell whose address locates the cell's `.so`.
pub type CellAnchor = extern "C" fn();

/// Why a cell's kernels could not be loaded.
#[derive(Debug, thiserror::Error)]
pub enum CellModuleError {
    /// `dladdr` did not map the anchor to a loaded object. Under evcxr this
    /// means the anchor was not defined in the cell.
    #[error("dladdr could not resolve the anchor to a shared object")]
    AnchorNotResolved,

    /// The shared object exists but its artifact section could not be read.
    #[error("failed to read artifact bundles from {}: {source}", path.display())]
    Bundles {
        path: PathBuf,
        #[source]
        source: EmbeddedModuleError,
    },

    /// The object has bundles, but none with the requested name. `found`
    /// lists the names that are there, which is usually enough to see why.
    #[error("no artifact bundle named {name:?} in {}; found {found:?}", path.display())]
    BundleNotFound {
        name: String,
        path: PathBuf,
        found: Vec<String>,
    },

    /// The bundle exists but carries no PTX, so this helper cannot load it.
    #[error("artifact bundle {name:?} has no PTX payload (this helper only loads PTX)")]
    NoPtx { name: String },

    /// The CUDA driver rejected the PTX or the module binding failed.
    #[error("CUDA driver error: {0}")]
    Driver(#[from] DriverError),
}

/// Path of the shared object that contains `anchor`.
pub fn cell_library_path(anchor: CellAnchor) -> Result<PathBuf, CellModuleError> {
    let mut info: libc::Dl_info = unsafe { std::mem::zeroed() };
    // SAFETY: `anchor` is a valid function pointer and `info` is a
    // zero-initialised out-parameter that dladdr fully overwrites on success.
    let found = unsafe { libc::dladdr(anchor as *const libc::c_void, &mut info) };
    if found == 0 || info.dli_fname.is_null() {
        return Err(CellModuleError::AnchorNotResolved);
    }
    // SAFETY: dladdr guarantees dli_fname is a NUL-terminated string that
    // stays valid for the lifetime of the loaded object.
    let name = unsafe { CStr::from_ptr(info.dli_fname) };
    Ok(PathBuf::from(OsStr::from_bytes(name.to_bytes())))
}

/// Read the PTX bundle called `bundle_name` from the cell that defines
/// `anchor` and load it into `ctx`.
///
/// Under evcxr the bundle is named after the cell crate, so pass
/// `env!("CARGO_PKG_NAME")` from the cell.
pub fn load_cell_module(
    ctx: &Arc<CudaContext>,
    anchor: CellAnchor,
    bundle_name: &str,
) -> Result<Arc<CudaModule>, CellModuleError> {
    let path = cell_library_path(anchor)?;
    let bundles = artifact_bundles_from_binary_path(&path).map_err(|source| {
        CellModuleError::Bundles {
            path: path.clone(),
            source,
        }
    })?;
    let bundle = bundles
        .iter()
        .find(|bundle| bundle.name == bundle_name)
        .ok_or_else(|| CellModuleError::BundleNotFound {
            name: bundle_name.to_owned(),
            path: path.clone(),
            found: bundles.iter().map(|bundle| bundle.name.clone()).collect(),
        })?;
    let ptx = bundle
        .payload(ArtifactPayloadKind::Ptx)
        .ok_or_else(|| CellModuleError::NoPtx {
            name: bundle_name.to_owned(),
        })?;
    Ok(ctx.load_module_from_image(ptx)?)
}

/// [`load_cell_module`] followed by the module's generated `from_module`,
/// which turns the raw [`CudaModule`] into the typed launch API.
pub fn bind_cell_module<T>(
    ctx: &Arc<CudaContext>,
    anchor: CellAnchor,
    bundle_name: &str,
    bind: impl FnOnce(Arc<CudaModule>) -> Result<T, DriverError>,
) -> Result<T, CellModuleError> {
    let module = load_cell_module(ctx, anchor, bundle_name)?;
    bind(module).map_err(CellModuleError::Driver)
}

/// Load the kernels of a `#[cuda_module] mod $module` defined in this cell.
///
/// Expands in the calling cell, so the anchor function and
/// `env!("CARGO_PKG_NAME")` both belong to the cell's own crate, which is
/// exactly what `dladdr` and the bundle lookup need.
///
/// Give the result an explicit type when it stays alive at the end of the
/// cell: evcxr persists such variables across cells and cannot infer the
/// name of the macro-generated type on its own.
///
/// ```ignore
/// let loaded: kernels::LoadedModule = colab_cuda_oxide::load_kernels!(&ctx, kernels).unwrap();
/// unsafe { loaded.vecadd(&stream, LaunchConfig::for_num_elems(n), &a, &b, &mut c) }.unwrap();
/// ```
///
/// cuda-oxide generates `from_module` as an `unsafe fn` when the module
/// declares a launch contract, with the obligation that the artifact being
/// bound was compiled from this very module. The macro discharges that
/// obligation by construction: it reads the bundle from the shared object
/// that contains this expansion, and evcxr compiles one cell per object, so
/// the bundle can only have come from the `$module` in this cell. Modules
/// without a contract expose a safe `from_module`, for which the `unsafe`
/// block is simply unused. Launch-contract modules are not yet exercised on
/// Colab; the vecadd path is.
#[macro_export]
macro_rules! load_kernels {
    ($ctx:expr, $module:ident) => {{
        extern "C" fn __colab_cuda_oxide_anchor() {}
        // SAFETY: see the macro documentation; the bundle is this cell's own.
        #[allow(unused_unsafe)]
        let bind = |module: ::std::sync::Arc<$crate::CudaModule>| unsafe { $module::from_module(module) };
        $crate::bind_cell_module($ctx, __colab_cuda_oxide_anchor, env!("CARGO_PKG_NAME"), bind)
    }};
}
