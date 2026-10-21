--!strict
-- A/B switch for the baked sword clips. false: the Kannagi Usagi retargets
-- (art/anim/kannagi_retarget.blend) play under the real clip names and the old katana.blend bake
-- is "Legacy_<name>". true: the old bake (and Clips.luau's hand-written reaction clips) are back
-- under the real names and the Kannagi clips are "K_<name>".
return {
	legacy = false,
}
