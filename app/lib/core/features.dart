/// Feature switches.
///
/// AI features (meal photo analysis, AI text parsing, AI summaries, the
/// nutrition chat) call a paid model through Edge Functions, so they are off
/// for now. Their buttons stay in the code behind this flag; turning it on
/// needs the matching Edge Functions deployed with AI_MODEL and the API key in
/// Supabase secrets. The app itself never holds a key or calls a model.
const bool kAiEnabled = false;

/// Recognising food in photos ON THE DEVICE (MobileCLIP, see
/// features/foods/photo_recognizer.dart). Free and offline, so it is on.
const bool kPhotoRecognition = true;

/// "Continue with Google". Needs a Supabase project with the Google provider
/// set up (README: Google sign-in); build with --dart-define=GOOGLE_SIGN_IN=true.
/// The local dev server has no Google login, so it is off by default.
const bool kGoogleSignIn = bool.fromEnvironment('GOOGLE_SIGN_IN');
