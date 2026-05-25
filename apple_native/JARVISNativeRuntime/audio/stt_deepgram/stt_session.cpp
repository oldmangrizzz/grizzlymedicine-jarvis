// stt_session.cpp
// JARVIS digital-personhood project — GMRI
//
// Concrete SttSession is implemented inside deepgram_stt.cpp as DeepgramSession.
// This file exists to satisfy the CMake target; no additional symbols here.

#include "stt_session.h"

namespace jarvis::audio::stt_deepgram {
// All methods are pure virtual on SttSession; concrete impl is DeepgramSession
// in deepgram_stt.cpp.
}  // namespace jarvis::audio::stt_deepgram
