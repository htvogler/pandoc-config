--[[remove additional * in case of strong emphasis in a strong text block created by Scrivener

**This is bold (strong) text with a ****_strong emphasized_**** part within**
--]]


function Str(elem)
  if elem.text == "****" then
    elem.text = ""
  end
  return elem
end