QUEST CHAIN LITE 1.4.0
World of Warcraft: Forever 1.60.1, interface 16001

Install

1. Quit WoW: Forever.
2. Extract the QuestChainLite folder into World of Warcraft\_forever_\Interface\AddOns.
   Replace the existing QuestChainLite files if you are updating.
   The resulting path should end in AddOns\QuestChainLite\QuestChainLite.toc.
3. Start Forever and check Quest Chain Lite in the character screen's AddOns list.
   Keep QuestieDB enabled if you have it. It comes with the current Forever Questie release.

Use

Open the standard quest log and hover a quest name. The normal tooltip shows a
short chain summary. Hovering a Questie quest pin on the world map shows the same
summary for that pin's quest. Quests with no known chain get no extra lines.

Open a quest in the map's quest log or at a quest giver to see its chain on a
parchment panel beside it. At quest givers it appears on the offer, progress and
reward pages. The opened quest is highlighted, turned-in quests get checkmarks,
and known dungeon steps have the dungeon icon. Long lists scroll. The panel
prefers the right side and moves left if needed. At a quest giver it stays hidden
if neither side has room. For branches or incomplete data, the list groups known
earlier quests and follow-ups.

Example

  [Chain icon] 3/4
  Requires: Pie for Billy
  Next: Goldtooth

A small gold chain link marks a quest chain. The game's dungeon entrance icon
marks chains where the current quest or a known later step is a dungeon quest.
That includes branches and outdoor lead-ins such as The Defias Brotherhood
before The Deadmines. Coverage depends on the quest links and dungeon details
available from Blizzard and QuestieDB.

The summary shows immediate links and up to three names per line. A step count
appears for an ordered Blizzard quest line or a linear path in QuestieDB. Branches
and incomplete chains can still show the links that are available.

Compatibility

Checked against Forever's published UI and quest API, local client 1.60.1.70862,
Questie 12.6.2 and QuestieDB 1.0.11. Tested with Lua 5.1, installed Forever quest
records and Questie's tooltip renderer. Live in-game verification is pending.
The Questie map integration uses its current tooltip renderer and may need an
update if Questie changes that renderer.

Blizzard UI source mirror
https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_UIPanels_Game/Mainline/QuestMapFrame.lua
https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_UIPanels_Game/Mainline/QuestFrame.lua

Questie Forever release and QuestieDB documentation
https://www.curseforge.com/wow/addons/questie/files/9467165
https://github.com/Questie/QuestieDB/blob/master/docs/api.md
