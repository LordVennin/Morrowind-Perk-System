# Brute Force - Lockpicking for Barbarians (OpenMW)

Break locks with the power of your muscles!

Thieves have lockpicks, wizards have spells, and what do barbarians have? A skill issue. I propose an immersive and vanilla-friendly approach to this problem.

## Features

### Split That Bastard in Half!

By hitting a locked door or container, you might strike the lock and force it open.  
The requirement is simple enough that any barbarian can figure it out:  
**Strength vs Lock Level + 25 (configurable)**  
So bring some sujamma next time you go adventuring.

Your weapon doesn't matter - but your skills do. The mod follows the vanilla hit chance formula, so that pesky little lock might still be tricky to hit.

Also make sure your weapon is in condition to break locks - they're really hard and wear it quite a bit!

But be careful!

### Don't Bend the Lock!

Since you're all brawn and no brains, you might just hit it the wrong way.  
Any lock has a **15% chance** to get bent in the process (configurable) and no longer "breakable", so keep a few Scrolls of Ondusi's Unhinging or an enchanted item handy.

This helps tone down the effectiveness of absurdly strong barbarians breaking every door in their way just by looking in their general direction.

This status is removed only when you unlock the lock the traditional way and open the door/container. So if you bend a lock, unlock it with a spell/lockpick/etc, and lock it back without interacting with the door/container, the lock will continue to count as "bent".

### And Don't Forget That Breaking Locks is LOUD!

It shouldn't be a surprise that hitting a lock with a chunk of metal (or anything, really) is loud. So breaking locks in tombs, ruins, or caves shouldn't make much of a difference, but in cities... let's just say, get ready to cause some ruckus.

If you hit an owned lock, two things happen for each present NPC:

1. **A long-distance line of sight check** (influenced by Sneak level) - NPC turns their head toward the noise and sees you with a weapon. Imagine the look on their face.
2. **A shorter-distance sound check** (influenced by Weapon Skill level) - NPC hears the loud noise even through a wall. Your crime is reported immediately.

At first I thought that it would be too restrictive. But let's be real - barbarians aren't supposed to be super good at thievery in the first place. They don't avoid combat - they initiate it!  
All values, of course, are configurable too.

## Requirements

[**Impact Effects**](https://www.nexusmods.com/morrowind/mods/55508) by taitechnic is a hard requirement.
**Load Brute Force after Impact Effects!**

## Consider Also

- [SHOP](https://www.nexusmods.com/morrowind/mods/57747) by **skrow42** - Allows NPC to bash doors too!
- [Oblivion-Style Lockpicking](https://www.nexusmods.com/morrowind/mods/56355) by **Ralts** - Completely overhauls lockpicking mechanic making it an actual mini-game

## Special Thanks

**taitechnic** - making Impact Effects, which is core to this mod and a fantastic mod by itself.  
**AOSity** - idea for alarming NPCs when breaking an owned lock.  
**skrow42** - code snippet for LOS NPC detection taken from his [SHOP](https://www.nexusmods.com/morrowind/mods/57747) mod  
**S3ctor** - helping navigate the API's quirks
