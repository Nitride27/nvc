# Pixel-art NITRIDE banner shown in every new WezTerm pane.
$letters = @(
  ("#....#", "##...#", "#.#..#", "#..#.#", "#...##", "#....#", "#....#"),  # N
  ("###", ".#.", ".#.", ".#.", ".#.", ".#.", "###"),                       # I
  ("#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."),         # T
  ("####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#"),         # R
  ("###", ".#.", ".#.", ".#.", ".#.", ".#.", "###"),                       # I
  ("####.", "#...#", "#...#", "#...#", "#...#", "#...#", "####."),         # D
  ("#####", "#....", "#....", "####.", "#....", "#....", "#####")          # E
)
$rows = 0..6 | ForEach-Object { $r = $_; (($letters | ForEach-Object { $_[$r] }) -join ".") + "." }
$rows += "." * $rows[0].Length  # room for the drop shadow

$e = [char]27
$block = [string][char]0x2588 * 2
$shadow = "$e[38;2;62;68;81m$block"  # one dark gutter grey
""
for ($y = 0; $y -lt $rows.Count; $y++) {
  # vertical fade from one dark blue to a deeper blue
  $t = $y / 6
  $fg = "$e[38;2;$([int](97 - 30 * $t));$([int](175 - 50 * $t));$([int](239 - 40 * $t))m$block"
  $line = "  "
  for ($x = 0; $x -lt $rows[$y].Length; $x++) {
    if ($rows[$y][$x] -eq '#') { $line += $fg }
    elseif ($y -gt 0 -and $x -gt 0 -and $rows[$y - 1][$x - 1] -eq '#') { $line += $shadow }
    else { $line += "  " }
  }
  Write-Host "$line$e[0m"
}
""
