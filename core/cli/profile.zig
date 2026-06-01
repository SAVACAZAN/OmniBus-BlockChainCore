//! Profile (DID + OBM + facets) + MiCA subcommands — re-exports.
const c = @import("common.zig");
pub const cmdProfileInit = c.cmdProfileInit;
pub const cmdProfileGet = c.cmdProfileGet;
pub const cmdProfileSocial = c.cmdProfileSocial;
pub const cmdProfileProfessional = c.cmdProfileProfessional;
pub const cmdProfileCultural = c.cmdProfileCultural;
pub const cmdProfileEconomic = c.cmdProfileEconomic;
pub const cmdProfileWizard = c.cmdProfileWizard;
pub const cmdProfileExport = c.cmdProfileExport;
pub const cmdProfileImport = c.cmdProfileImport;
pub const cmdProfile = c.cmdProfile;
pub const cmdMicaAttest = c.cmdMicaAttest;
pub const cmdMicaDisclose = c.cmdMicaDisclose;
pub const cmdMica = c.cmdMica;
