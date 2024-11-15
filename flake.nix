{
  description = "Static files for my personal website.";

  outputs = { self }: {
    website = {
      src = ./public;
    };
  };
}
